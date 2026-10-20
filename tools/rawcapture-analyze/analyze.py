#!/usr/bin/env python3
"""Report on a Scan4D raw-capture dump: still rate and spacing, what the blur gate saw against the
motion the gyro actually recorded, the same motion re-evaluated at an older shutter, depth cadence
through the moments stills were in flight, and the achieved IMU rates.

    python analyze.py raw_capture_Office_20261020_101500.zip
    python analyze.py /path/to/extracted/dir [--old-exposure 0.0333] [--budget-px 2]

Reads only the CSVs and manifest.json, so a zip is used as-is: no extraction, no image decode.
Timestamps in every file are on the same host clock (seconds since boot), which is what makes the
gyro integrals below meaningful. numpy only.
"""
import argparse
import csv
import io
import json
import sys
import zipfile
from pathlib import Path

import numpy as np

TRAPZ = getattr(np, "trapezoid", None) or np.trapz  # numpy 2 renamed it


class Dump:
    """A dump directory or its zip; file lookup by basename, directory prefix ignored."""

    def __init__(self, path):
        self.path = Path(path)
        self.zip = zipfile.ZipFile(self.path) if self.path.is_file() else None
        self.names = self.zip.namelist() if self.zip else None

    def text(self, name):
        if self.zip:
            hits = [n for n in self.names if n == name or n.endswith("/" + name)]
            return self.zip.read(hits[0]).decode("utf-8") if hits else None
        p = self.path / name
        return p.read_text() if p.exists() else None


def rows(text):
    return list(csv.DictReader(io.StringIO(text))) if text else []


def column(table, key):
    out = []
    for r in table:
        v = (r.get(key) or "").strip()
        if v == "inf":
            out.append(np.inf)
            continue
        try:
            out.append(float(v))
        except ValueError:
            out.append(np.nan)
    return np.array(out, dtype=float)


def pct(a, q):
    a = a[np.isfinite(a)]
    return float(np.percentile(a, q)) if a.size else float("nan")


def fmt(x, digits=2):
    return "n/a" if x is None or not np.isfinite(x) else f"{x:.{digits}f}"


def section(title):
    print(f"\n== {title} ==")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dump", help="raw_capture_*.zip or the extracted directory")
    ap.add_argument("--old-exposure", type=float, default=1 / 30,
                    help="shutter for the counterfactual 'old settings' smear (default 1/30 s, what AE chose uncapped)")
    ap.add_argument("--old-gate", type=float, default=0.5,
                    help="angular-rate ceiling of the old gate, rad/s (default 0.5)")
    ap.add_argument("--budget-px", type=float, default=2.0, help="smear budget to score against (default 2 px)")
    args = ap.parse_args()

    d = Dump(args.dump)
    manifest = json.loads(d.text("manifest.json") or "{}")
    setup, totals = manifest.get("setup", {}), manifest.get("totals", {})
    photos = rows(d.text("photos.csv"))
    gyro = rows(d.text("imu_gyro.csv"))
    depth = rows(d.text("depth_frames.csv"))
    if not photos:
        sys.exit("no photos.csv in the dump")

    section("setup")
    for key in ("deviceModel", "videoFormat", "maxPhotoDimensions", "depthFormat", "photoCodec",
                "qualityPrioritization", "depthDeliverySupported", "depthDeliveryEnabled",
                "maxExposureCapSeconds", "blurBudgetPx", "photoFocalPxEstimate",
                "stillSpacingRotationDeg", "stillSpacingShiftFraction",
                "stillMinIntervalSeconds", "stillMaxIntervalSeconds"):
        if key in setup:
            print(f"  {key}: {setup[key]}")

    # ---- stills: rate and spacing ------------------------------------------------------------
    order = np.argsort(column(photos, "host_ts"))
    photos = [photos[i] for i in order]
    t = column(photos, "host_ts")
    n = len(t)
    duration = float(t[-1] - t[0]) if n > 1 else 0.0
    section("stills")
    print(f"  {n} stills over {duration:.1f} s  =  {n / duration * 60 if duration else float('nan'):.1f} / min")
    latency = column(photos, "latency_s")
    print(f"  pipeline latency (request -> capture): median {fmt(pct(latency, 50))} s, p90 {fmt(pct(latency, 90))} s")
    if n > 1:
        dt = np.diff(t)
        print(f"  interval between stills: median {fmt(pct(dt, 50))} s, p10 {fmt(pct(dt, 10))}, p90 {fmt(pct(dt, 90))}")
    print(f"  gate holds for blur: {totals.get('photos_gated', 'n/a')}   (checks, one per retry tick)")
    reasons = [r.get("spacing_reason", "") for r in photos if r.get("spacing_reason")]
    if reasons:
        counts = {k: reasons.count(k) for k in sorted(set(reasons))}
        print(f"  spacing reason per still: {counts}")

    # ---- gyro-derived motion -----------------------------------------------------------------
    gt = column(gyro, "host_ts")
    gw = np.stack([column(gyro, "rot_x"), column(gyro, "rot_y"), column(gyro, "rot_z")], axis=1) if gyro else np.zeros((0, 3))
    if gt.size:
        g_order = np.argsort(gt)
        gt, gw = gt[g_order], gw[g_order]
    rate_norm = np.linalg.norm(gw, axis=1) if gt.size else np.zeros(0)

    def rotation_between(t0, t1):
        """Rotation vector integral between two times, degrees (small-angle; fine between stills)."""
        if gt.size < 2:
            return np.nan
        i0, i1 = np.searchsorted(gt, [t0, t1])
        if i1 - i0 < 2:
            j = min(max(i0, 1), gt.size - 1)
            return float(np.linalg.norm(gw[j - 1:j + 1].mean(axis=0)) * (t1 - t0) * 180 / np.pi)
        return float(np.linalg.norm(TRAPZ(gw[i0:i1], gt[i0:i1], axis=0)) * 180 / np.pi)

    def mean_rate(t0, t1):
        """Mean |omega| over a window, rad/s; nearest samples when the window is shorter than one."""
        if gt.size == 0:
            return np.nan
        i0, i1 = np.searchsorted(gt, [t0 - 0.01, t1 + 0.01])
        if i1 <= i0:
            j = min(max(i0, 0), gt.size - 1)
            return float(rate_norm[j])
        return float(rate_norm[i0:i1].mean())

    if n > 1 and gt.size:
        section("viewpoint change between consecutive stills")
        rot = np.array([rotation_between(t[i], t[i + 1]) for i in range(n - 1)])
        print(f"  rotation (gyro integral): median {fmt(pct(rot, 50), 1)} deg, p10 {fmt(pct(rot, 10), 1)}, p90 {fmt(pct(rot, 90), 1)}")
        print(f"  that is about {fmt(10 / pct(rot, 50), 1)} stills per 10 degrees of pan at the median")
        app_rot = column(photos, "rotation_since_prev_deg")
        if np.isfinite(app_rot).any():
            print(f"  app's attitude-based figure at request: median {fmt(pct(app_rot, 50), 1)} deg")
        shift = column(photos, "shift_since_prev_frac")
        if np.isfinite(shift).any():
            print(f"  image shift since previous still (fraction of frame width): median {fmt(pct(shift, 50), 3)}, p90 {fmt(pct(shift, 90), 3)}")
        print("  to thin the stills, set the spacing thresholds near the per-still change you want;")
        print("  e.g. 1.5x the median rotation above for roughly two thirds of this rate while panning")

    # ---- blur: what the gate saw, what the gyro says happened, and the old shutter ------------
    exposure = column(photos, "exposure_s")
    fx, ref_w, width = column(photos, "fx"), column(photos, "ref_width"), column(photos, "width")
    focal_est = float(setup.get("photoFocalPxEstimate", np.nan) or np.nan)
    fx_photo = np.where((ref_w > 0) & np.isfinite(fx), fx * width / np.where(ref_w > 0, ref_w, 1), focal_est)
    if gt.size and np.isfinite(fx_photo).any():
        section("blur")
        print(f"  focal length used: median {fmt(pct(fx_photo, 50), 0)} px   exposure: median 1/{fmt(1 / pct(exposure, 50), 0)} s")
        actual = np.array([mean_rate(t[i], t[i] + exposure[i]) * exposure[i] * fx_photo[i] for i in range(n)])
        print(f"  actual rotational smear (gyro over the exposure): median {fmt(pct(actual, 50))} px, p90 {fmt(pct(actual, 90))} px,"
              f" over budget ({args.budget_px} px): {int(np.sum(actual > args.budget_px))} of {n}")
        predicted = column(photos, "predicted_smear_px")
        if np.isfinite(predicted).any():
            err = np.abs(predicted - actual)
            print(f"  gate's single-sample prediction vs actual: median |diff| {fmt(pct(err, 50))} px, p90 {fmt(pct(err, 90))} px")
        old = np.array([mean_rate(t[i], t[i] + args.old_exposure) * args.old_exposure * fx_photo[i] for i in range(n)])
        held = np.array([mean_rate(t[i], t[i] + args.old_exposure) > args.old_gate for i in range(n)])
        print(f"  same motion at 1/{1 / args.old_exposure:.0f} s: median {fmt(pct(old, 50))} px, p90 {fmt(pct(old, 90))} px,"
              f" over {args.budget_px} px: {int(np.sum(old > args.budget_px))} of {n}, over 5 px: {int(np.sum(old > 5))} of {n}")
        print(f"  of those, the old {args.old_gate} rad/s gate would have held: {int(np.sum(held))}"
              f"  (so {int(np.sum((old > args.budget_px) & ~held))} stills would have been blurred AND admitted)")
        print("  translational smear is not in these numbers: it needs distance to the surface and a pose")

    # ---- depth cadence ----------------------------------------------------------------------
    dte = column(depth, "host_ts")
    if dte.size > 2:
        section("depth stream")
        dte = np.sort(dte[np.isfinite(dte)])
        dd = np.diff(dte)
        med = pct(dd, 50)
        gaps = dd > 3 * med
        dropped = column(depth, "depth_dropped")
        print(f"  {dte.size} frames, {int(np.nansum(dropped))} flagged dropped, interval median {fmt(med * 1000, 1)} ms,"
              f" p99 {fmt(pct(dd, 99) * 1000, 1)} ms, max {fmt(dd.max() * 1000, 1)} ms, gaps over 3x median: {int(gaps.sum())}")
        req = column(photos, "request_host_ts")
        if gaps.any() and np.isfinite(req).any():
            gap_starts = dte[:-1][gaps]
            windows = [(req[i], t[i]) for i in range(n) if np.isfinite(req[i]) and req[i] >= 0]
            inside = sum(any(a <= g <= b for a, b in windows) for g in gap_starts)
            in_flight = sum(max(0.0, b - a) for a, b in windows)
            print(f"  gaps starting while a still was in flight: {inside} of {int(gaps.sum())}"
                  f"  (in-flight time was {fmt(in_flight / duration * 100 if duration else np.nan, 0)}% of the capture)")

    # ---- IMU --------------------------------------------------------------------------------
    section("imu")
    for name in ("gyro", "accel", "devicemotion", "magnetometer"):
        hz, samples = totals.get(f"{name}_hz"), totals.get(f"{name}_samples")
        if hz is not None:
            print(f"  {name}: {samples} samples at {hz:.1f} Hz achieved")
    if gt.size > 2:
        gdt = np.diff(gt)
        print(f"  gyro interval from the file: median {fmt(pct(gdt, 50) * 1000, 2)} ms, max {fmt(gdt.max() * 1000, 1)} ms")


if __name__ == "__main__":
    main()
