#!/usr/bin/env python3
"""Normalize a Scan4D capture into a plain dataset: ARKit's quirks fixed once, at the source.

    python normalize.py IN OUT [--device MODEL] [--pad M]

IN is the app's Scan4D export (cameras/ + images/: the room-scan export), an older app Nerfstudio
export (transforms.json + cameras/) or an AR Capture dump (manifest.json + photos.csv: the focus-scan
capture). OUT is a Nerfstudio dataset (the contract is in flows/_lib/nsdataset.py) in which:

  frames       (exports) transforms.json built from cameras/, one Polycam record per image with its
               own pose (row-major, ARKit's axes, which are Nerfstudio's) and intrinsics, so every
               frame carries its own: Nerfstudio never reads a frame's value for a key set globally.
  intrinsics   ARKit reports each high-resolution still with the video's intrinsics scaled up, but
               the still's field of view is narrower. The true still focal is a per-device constant
               (DEVICE_FOCAL), corrected here for known devices; 12 MP stills only, never video frames
               or 360 rig faces. An unknown device is left as reported, and normalize.json says so
               (sfm-poses intrinsics=refine solves it).
  depth        ARKit's LiDAR follows the video geometry, not the still's. It is resampled (nearest)
               into each image's own geometry at the image's size (LichtFeld requires the image size),
               16-bit millimetres; confidence with it, on its own grid. Depth the app wrote byte-swapped
               (scans captured before wisescan-ios #93) is read the right way round.
  masks        (exports) the 360 rig faces' operator/rig masks, resampled to the face's size.
  fillers      (exports) Nerfstudio wants depth and masks on every frame or on none: a frame without
               depth gets all-zero depth (both engines ignore zeros), one without a mask an all-keep one.
  timestamps   (dumps) each still's capture time, and the session's ~30 Hz pose log as
               pose_stream.csv: what lets sfm-poses tell an ARKit jump from an SfM slide.
  world_up     [0, 1, 0]: ARKit's world is gravity-aligned.
  region.json  (dumps) the focus box; (exports) RoomPlan's floor polygon extruded floor to ceiling,
               padded by --pad, doors and windows kept as rectangles; non-convex rooms keep their shape.

Everything else in an export (mesh, RoomPlan, registration, cameras/, the 360 originals) is carried over
unchanged, so scan4d-priors runs on the result as on the export. Images are hard-linked where the
filesystem allows; every rewritten file is a new file, so the input is never modified.
"""
import argparse
import csv
import json
import os
import shutil
from concurrent.futures import ProcessPoolExecutor

import numpy as np
from PIL import Image
from scipy.spatial import ConvexHull

# Still focal / ARKit-reported focal for 12 MP stills (4032 x 3024), measured per device by multi-view
# focal refits with the poses fixed. focal/width bands identify the device in an export, which names none.
DEVICE_FOCAL = {"iPad13,9": 1.0476, "iPhone18,1": 1.0136}
FOCAL_PER_WIDTH = (("iPad13,9", 0.77, 0.82), ("iPhone18,1", 0.68, 0.72))
STILL_SIZE = (4032, 3024)


def link_or_copy(src, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if os.path.exists(dst):
        os.remove(dst)
    try:
        os.link(src, dst)
    except OSError:
        shutil.copy2(src, dst)


def plane(path):
    a = np.asarray(Image.open(path))
    return a[..., 0] if a.ndim == 3 else a


def millimetres(a):
    """16-bit depth as millimetres. The app wrote its LiDAR PNGs byte-swapped until wisescan-ios #93
    (DepthPNG.swift), and scans captured before it still are. Real depth lands in 0.1-20 m and the wrong
    byte order scatters over the whole 16-bit range, so a vote over the samples settles it."""
    a = a.astype(np.uint16)
    v = a[a > 0]
    plausible = lambda x: np.count_nonzero((x >= 100) & (x <= 20000))   # noqa: E731
    return a.byteswap() if plausible(v.byteswap()) > plausible(v) else a


def centre_samples(a, h, w):
    """a at h x w by each target cell's centre pixel: exact for a nearest-neighbour stretch."""
    H, W = a.shape
    return a[np.ix_(((np.arange(h) + .5) * H / h).astype(int), ((np.arange(w) + .5) * W / w).astype(int))]


def still_from_video(a, W, H, cx, cy, k, h, w):
    """A raster in the video geometry (any size, the still's field of view scaled by k) -> h x w in the
    still's geometry: still pixel -> ray at the still focal -> video pixel -> source cell."""
    sh, sw = a.shape
    u = (np.arange(w) + .5) * W / w
    v = (np.arange(h) + .5) * H / h
    uu = np.clip(((cx + (u - cx) / k) * sw / W).astype(int), 0, sw - 1)
    vv = np.clip(((cy + (v - cy) / k) * sh / H).astype(int), 0, sh - 1)
    return a[np.ix_(vv, uu)]


def write_new(path, arr):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp.png"
    Image.fromarray(arr).save(tmp)
    os.replace(tmp, path)


def resample_job(job):
    """One image's depth and confidence into its own geometry, depth at its size."""
    depth_src, conf_src, depth_dst, conf_dst, W, H, cx, cy, k, native = job
    d = millimetres(plane(depth_src))
    c = plane(conf_src) if conf_src else None
    nh, nw = c.shape if c is not None else native
    if d.shape != (nh, nw):
        d = centre_samples(d, nh, nw)                 # the export stretched it to the still's size
    write_new(depth_dst, still_from_video(d, W, H, cx, cy, k, H, W).astype(np.uint16))
    if c is not None:
        write_new(conf_dst, still_from_video(c, W, H, cx, cy, k, nh, nw).astype(np.uint8))
    return depth_dst


def mask_job(job):
    """One 360 face's mask at the face's size (the export's are a quarter of it). White keeps."""
    src, dst, W, H = job
    write_new(dst, centre_samples(plane(src), H, W).astype(np.uint8))
    return dst


def fill_job(job):
    """A filler at the image's size: all-zero depth, or an all-keep mask."""
    dst, W, H, value, dtype = job
    write_new(dst, np.full((H, W), value, dtype))
    return dst


def run_job(job):
    """A process-pool task: (function, its arguments)."""
    fn, args = job
    return fn(args)


# --- regions ------------------------------------------------------------------------------------

def colmajor(m):
    return np.array(m, float).reshape(4, 4).T


def room(raw, pad):
    """RoomPlan's floor polygon (or the walls' hull) extruded floor to ceiling, in a frame yawed to its
    minimum-area rectangle; doors, windows and openings as rectangles in that frame."""
    walls = raw.get("walls", [])
    if not walls:
        return None
    wall_T = [colmajor(w["transform"]) for w in walls]
    floor = next((f for f in raw.get("floors", []) if f.get("polygonCorners")), None)
    if floor:
        Tf = colmajor(floor["transform"])
        pts = np.array([Tf @ [c[0], c[1], 0, 1] for c in floor["polygonCorners"]])[:, :3]
        floor_y, source = Tf[1, 3], "RoomPlan floor polygon"
    else:
        ends = np.array([T[:3, 3] + s * w["dimensions"][0] / 2 * T[:3, 0] for w, T in zip(walls, wall_T) for s in (-1, 1)])
        pts = ends[ConvexHull(ends[:, [0, 2]]).vertices]
        floor_y, source = min(T[1, 3] - w["dimensions"][1] / 2 for w, T in zip(walls, wall_T)), "convex hull of the RoomPlan walls"
    ceiling_y = max(T[1, 3] + w["dimensions"][1] / 2 for w, T in zip(walls, wall_T))
    xz = pts[:, [0, 2]]

    def flat(th):
        c, s = np.cos(th), np.sin(th)
        return np.stack([c * xz[:, 0] - s * xz[:, 1], s * xz[:, 0] + c * xz[:, 1]], 1)
    th = min(np.radians(np.arange(0, 90, .1)), key=lambda t: np.prod(np.ptp(flat(t), 0)))
    c, s = np.cos(th), np.sin(th)
    R = np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])
    q = flat(th)
    mid = (q.min(0) + q.max(0)) / 2
    Tr = np.eye(4)
    Tr[:3, :3] = R
    Tr[:3, 3] = R @ [mid[0], (floor_y + ceiling_y) / 2, mid[1]]
    h = ceiling_y - floor_y
    openings = []
    for kind in ("doors", "windows", "openings"):
        for o in raw.get(kind, []):
            To = colmajor(o["transform"])
            w_, h_ = o["dimensions"][:2]
            openings.append(dict(kind=kind[:-1], centre=(R.T @ (To[:3, 3] - Tr[:3, 3])).tolist(),
                                 u=(R.T @ To[:3, 0] * w_ / 2).tolist(), v=(R.T @ To[:3, 1] * h_ / 2).tolist()))
    return dict(kind="prism", label="room", to_world=Tr.tolist(), polygon_xz=(q - mid).tolist(), y_range=[-h / 2, h / 2],
                pad_m=pad, openings=openings, source=source)


def focus_box(setup):
    if not (setup.get("regionToWorld") and setup.get("focusRegion")):
        return None
    size = np.array(setup["focusRegion"]["size_m"], float)
    return dict(kind="box", label=setup["focusRegion"].get("label", ""), to_world=colmajor(setup["regionToWorld"]).tolist(),
                min=(-size / 2).tolist(), max=(size / 2).tolist(), source="focus region")


# --- the two inputs ------------------------------------------------------------------------------

def from_dump(src, out, device):
    setup = json.load(open(f"{src}/manifest.json"))["setup"]
    given = bool(device)
    device = device or setup.get("deviceModel", "")
    k = DEVICE_FOCAL.get(device)
    rows = list(csv.DictReader(open(f"{src}/photos.csv")))
    frames, jobs = [], []
    for r in rows:
        stem = os.path.splitext(os.path.basename(r["file"]))[0]
        W, H = int(r["width"]), int(r["height"])
        fx, fy, cx, cy = (float(r[x]) for x in ("fx", "fy", "cx", "cy"))
        s = k if (k and (W, H) == STILL_SIZE) else 1.0
        link_or_copy(f"{src}/{r['file']}", f"{out}/images/{os.path.basename(r['file'])}")
        m = np.eye(4)
        m[:3] = np.array([[float(r[f"c2w_{i}{j}"]) for j in range(4)] for i in range(3)])
        e = dict(file_path=f"images/{os.path.basename(r['file'])}", transform_matrix=m.tolist(), timestamp=float(r["host_ts"]),
                 fl_x=fx * s, fl_y=fy * s, cx=cx, cy=cy, w=W, h=H)
        if r.get("exposure_s"):
            e["exposure_duration_s"] = float(r["exposure_s"])
        if r.get("depth_file"):
            e["depth_file_path"] = f"depth/{stem}.png"
            jobs.append((resample_job, (f"{src}/{r['depth_file']}", f"{src}/{r['confidence_file']}" if r.get("confidence_file") else None,
                                        f"{out}/depth/{stem}.png", f"{out}/confidence/{stem}.png", W, H, cx, cy, s,
                                        (int(r.get("depth_height") or 192), int(r.get("depth_width") or 256)))))
            if r.get("confidence_file"):
                e["confidence_file_path"] = f"confidence/{stem}.png"
        frames.append(e)
    meta = dict(camera_model="OPENCV", k1=0.0, k2=0.0, p1=0.0, p2=0.0, frames=frames)
    if os.path.exists(f"{src}/frames.csv"):
        with open(f"{src}/frames.csv") as fi, open(f"{out}/pose_stream.csv", "w", newline="") as fo:
            rd = csv.DictReader(fi)
            cols = [f"c2w_{i}{j}" for i in range(3) for j in range(4)]
            wr = csv.writer(fo)
            wr.writerow(["timestamp", "tracking", *cols])
            n = 0
            for r in rd:
                wr.writerow([r["host_ts"], r.get("tracking", "normal"), *(r[c] for c in cols)])
                n += 1
        meta["pose_stream_path"] = "pose_stream.csv"
    region = focus_box(setup)
    stills = sum(1 for e in frames if (e["w"], e["h"]) == STILL_SIZE)
    info = dict(source="ar capture dump", device=device or None, device_source="--device" if given else "manifest",
                still_focal_scale=k, corrected=stills if k else 0, uncorrected_stills=0 if k else stills, depth_frames=len(jobs))
    return meta, jobs, region, info


def device_of(frames):
    ratios = [f["fl_x"] / f["w"] for f in frames if (f["w"], f["h"]) == STILL_SIZE]
    if not ratios:
        return None, None
    r = float(np.median(ratios))
    return next((d for d, lo, hi in FOCAL_PER_WIDTH if lo <= r <= hi), None), r


def device_source(device, inferred, ratio):
    return ("--device" if device and device != inferred else f"inferred from focal/width {ratio:.3f}" if inferred
            else f"focal/width {ratio:.3f} matches no known device" if ratio else "no 12 MP stills")


def carry_over(src, out, rewrite):
    """Everything in src but what this stage rewrites, linked into out. The rewritten names include this
    stage's own output, for when IN is an earlier stage's folder."""
    for name in os.listdir(src):
        if name in rewrite | {"manifest.json", "normalize.json", "region.json"}:
            continue
        p = f"{src}/{name}"
        if os.path.isdir(p):
            shutil.copytree(p, f"{out}/{name}", copy_function=link_or_copy, dirs_exist_ok=True)
        else:
            link_or_copy(p, f"{out}/{name}")


def from_bundle(src, out, device, pad):
    tf = json.load(open(f"{src}/transforms.json"))
    carry_over(src, out, {"transforms.json", "depth", "confidence"})
    g = lambda f, key: f.get(key, tf.get(key))       # noqa: E731
    frames = [dict(f, **{key: g(f, key) for key in ("fl_x", "fl_y", "cx", "cy", "w", "h")}) for f in tf["frames"]]
    inferred, ratio = device_of(frames)
    device = device or inferred
    k = DEVICE_FOCAL.get(device)
    jobs, corrected, with_depth = [], 0, 0
    for f in frames:
        W, H = int(f["w"]), int(f["h"])
        s = k if (k and (W, H) == STILL_SIZE and abs(f["fl_x"] / W - ratio) < 0.02) else 1.0
        corrected += s != 1.0
        f["fl_x"], f["fl_y"] = f["fl_x"] * s, f["fl_y"] * s
        for key in ("depth_file_path", "confidence_file_path"):
            if f.get(key) and not os.path.exists(f"{src}/{f[key]}"):
                f.pop(key)
        if not f.get("depth_file_path"):
            continue
        with_depth += 1
        conf = f.get("confidence_file_path")
        if s != 1.0:
            jobs.append((resample_job, (f"{src}/{f['depth_file_path']}", f"{src}/{conf}" if conf else None,
                                        f"{out}/{f['depth_file_path']}", f"{out}/{conf}" if conf else None,
                                        W, H, f["cx"], f["cy"], s, (192, 256))))
        else:                       # unknown device, a video frame, or a filler: already in its image's geometry
            for key in ("depth_file_path", "confidence_file_path"):
                if f.get(key):
                    link_or_copy(f"{src}/{f[key]}", f"{out}/{f[key]}")
    meta = {key: v for key, v in tf.items() if key not in ("frames", "fl_x", "fl_y", "cx", "cy", "w", "h")}
    meta["frames"] = frames
    region = None
    if os.path.exists(f"{src}/roomplan_raw.json"):
        region = room(json.load(open(f"{src}/roomplan_raw.json")), pad)
    stills = sum(1 for f in frames if (int(f["w"]), int(f["h"])) == STILL_SIZE)
    info = dict(source="nerfstudio export", device=device, device_source=device_source(device, inferred, ratio),
                still_focal_scale=k, corrected=corrected, uncorrected_stills=stills - corrected, depth_frames=with_depth)
    return meta, jobs, region, info


# Camera-record keys passed through to transforms.json for triage; both engines ignore keys they don't know.
PASSTHROUGH = ("is_keyframe", "sharpness", "exposure_duration_s", "face", "still_source", "camera_pose_source")


def from_export(src, out, device, pad):
    """The Scan4D export: a Polycam record per image in cameras/ (t_rc is row r, column c of the
    camera-to-world matrix), depth and confidence at the LiDAR's raster, masks for the 360 rig faces only.
    Its transforms.json is built from cameras/, as the app's Nerfstudio export built it."""
    carry_over(src, out, {"depth", "confidence", "masks"})
    frames, skipped = [], 0
    for name in sorted(n for n in os.listdir(f"{src}/cameras") if n.endswith(".json")):
        stem = name[:-len(".json")]
        try:
            cam = json.load(open(f"{src}/cameras/{name}"))
            rows = [[float(cam[f"t_{r}{c}"]) for c in range(4)] for r in range(3)]
            f = dict(file_path=cam.get("image_path") or f"images/{stem}.jpg", transform_matrix=rows + [[0.0, 0.0, 0.0, 1.0]],
                     fl_x=float(cam["fx"]), fl_y=float(cam["fy"]), cx=float(cam["cx"]), cy=float(cam["cy"]),
                     w=int(cam["width"]), h=int(cam["height"]))
        except (KeyError, TypeError, ValueError):
            skipped += 1
            continue
        if not os.path.exists(f"{src}/{f['file_path']}"):
            skipped += 1
            continue
        f.update({key: cam[key] for key in PASSTHROUGH if key in cam})
        sidecars = {key: cam[key] for key in ("depth_path", "confidence_path")
                    if cam.get(key) and os.path.exists(f"{src}/{cam[key]}")}
        frames.append((stem, f, sidecars))
    if not frames:
        raise SystemExit(f"{src}/cameras: no camera record whose image is in the export")

    inferred, ratio = device_of([f for _, f, _ in frames])
    device = device or inferred
    k = DEVICE_FOCAL.get(device)
    jobs, corrected, masked = [], 0, 0
    for stem, f, sidecars in frames:
        W, H = f["w"], f["h"]
        s = k if (k and (W, H) == STILL_SIZE and abs(f["fl_x"] / W - ratio) < 0.02) else 1.0
        corrected += s != 1.0
        f["fl_x"], f["fl_y"] = f["fl_x"] * s, f["fl_y"] * s
        if "depth_path" in sidecars:
            f["depth_file_path"] = f"depth/{stem}.png"
            conf = sidecars.get("confidence_path")
            if conf:
                f["confidence_file_path"] = f"confidence/{stem}.png"
            jobs.append((resample_job, (f"{src}/{sidecars['depth_path']}", f"{src}/{conf}" if conf else None,
                                        f"{out}/depth/{stem}.png", f"{out}/confidence/{stem}.png" if conf else None,
                                        W, H, f["cx"], f["cy"], s, (192, 256))))
        if os.path.exists(f"{src}/masks/{stem}.png"):
            f["mask_path"] = f"masks/{stem}.png"
            jobs.append((mask_job, (f"{src}/masks/{stem}.png", f"{out}/masks/{stem}.png", W, H)))
            masked += 1

    # Nerfstudio asserts depth and masks are on every frame or on none, so the frames without them get
    # fillers: zeros, which both engines skip as no depth, and white, which masks nothing.
    with_depth = sum("depth_file_path" in f for _, f, _ in frames)
    fillers = {"depth": 0, "masks": 0}
    for stem, f, _ in frames:
        for key, kind, value, dtype, any_real in (("depth_file_path", "depth", 0, np.uint16, with_depth),
                                                  ("mask_path", "masks", 255, np.uint8, masked)):
            if any_real and key not in f:
                f[key] = f"{kind}/{stem}.png"
                jobs.append((fill_job, (f"{out}/{f[key]}", f["w"], f["h"], value, dtype)))
                fillers[kind] += 1

    meta = dict(camera_model="OPENCV", k1=0.0, k2=0.0, p1=0.0, p2=0.0, frames=[f for _, f, _ in frames])
    region = None
    if os.path.exists(f"{src}/roomplan_raw.json"):
        region = room(json.load(open(f"{src}/roomplan_raw.json")), pad)
    stills = sum(1 for _, f, _ in frames if (f["w"], f["h"]) == STILL_SIZE)
    info = dict(source="scan4d export", device=device, device_source=device_source(device, inferred, ratio),
                still_focal_scale=k, corrected=corrected, uncorrected_stills=stills - corrected, depth_frames=with_depth,
                masks=masked, fillers=fillers, skipped_cameras=skipped)
    return meta, jobs, region, info


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--device", default=None, help="device model, when the capture does not say (DEVICE_FOCAL keys)")
    ap.add_argument("--pad", type=float, default=0.15, help="room region: outward pad on walls, floor and ceiling (m)")
    a = ap.parse_args()
    src, out = os.path.abspath(a.input), os.path.abspath(a.output)
    if os.path.realpath(src) == os.path.realpath(out):
        raise SystemExit("OUT must differ from IN")
    os.makedirs(out, exist_ok=True)
    if os.path.exists(f"{src}/transforms.json"):
        meta, jobs, region, info = from_bundle(src, out, a.device, a.pad)
    elif os.path.isdir(f"{src}/cameras"):
        meta, jobs, region, info = from_export(src, out, a.device, a.pad)
    elif os.path.exists(f"{src}/manifest.json") and os.path.exists(f"{src}/photos.csv"):
        meta, jobs, region, info = from_dump(src, out, a.device)
    else:
        raise SystemExit(f"{src} is neither a Scan4D export nor an AR Capture dump")
    with ProcessPoolExecutor(max_workers=min(8, os.cpu_count() or 1)) as pool:
        list(pool.map(run_job, jobs, chunksize=4))
    if info["depth_frames"]:
        meta["depth_unit_scale_factor"] = 0.001
    meta["world_up"] = [0.0, 1.0, 0.0]
    if region:
        with open(f"{out}/region.json", "w") as fh:
            json.dump(region, fh, indent=1)
    tmp = f"{out}/transforms.json.tmp"
    with open(tmp, "w") as fh:
        json.dump(meta, fh, indent=2)
    os.replace(tmp, f"{out}/transforms.json")
    info.update(frames=len(meta["frames"]), depth_resampled=sum(fn is resample_job for fn, _ in jobs),
                pose_stream=bool(meta.get("pose_stream_path")),
                region=(region or {}).get("kind"))
    with open(f"{out}/normalize.json", "w") as fh:
        json.dump(info, fh, indent=1)
    scale = f"{info['still_focal_scale']}" if info["still_focal_scale"] else "unknown device: left as reported"
    print(f"normalize: {info['source']}, {info['frames']} frames ({info['depth_frames']} with depth); device {info['device'] or 'unknown'}"
          f" ({info['device_source']}); still focal x{scale} on {info['corrected']} stills; pose stream {'yes' if info['pose_stream'] else 'no'};"
          f" region {info['region'] or 'none'}")


if __name__ == "__main__":
    main()
