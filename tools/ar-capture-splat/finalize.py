"""Stage 5 (CPU, seconds): hard-crop the trained splat to the box and write the run summary.

    python finalize.py OUT RUN        (RUN = training output folder under OUT, holding full.ply)

Writes OUT/RUN/splat.ply (inside the box only) and OUT/RUN/summary.json (pose solve, box, LichtFeld
held-out metrics, opacity outside the box before the crop).
"""
import json
import os
import sys

import numpy as np


def read_ply(path):
    with open(path, "rb") as f:
        header = b""
        while not header.endswith(b"end_header\n"):
            header += f.readline()
    props, n = [], 0
    types = {"float": "<f4", "double": "<f8", "uchar": "u1"}
    for line in header.decode().splitlines():
        if line.startswith("element vertex"):
            n = int(line.split()[2])
        if line.startswith("property"):
            props.append((line.split()[2], types[line.split()[1]]))
    return header, np.memmap(path, dtype=np.dtype(props), mode="r", offset=len(header), shape=(n,))


def main(out, run):
    work, rd = f"{out}/work", f"{out}/{run}"
    box = json.load(open(f"{work}/box.json"))
    T, LO, HI = np.array(box["box_to_model"]), np.array(box["min"]), np.array(box["max"])
    header, v = read_ply(f"{rd}/full.ply")
    X = np.stack([v["x"], v["y"], v["z"]], 1).astype(np.float64)
    op = 1 / (1 + np.exp(-v["opacity"].astype(np.float64)))
    keep = np.all(((X - T[:3, 3]) @ T[:3, :3] >= LO) & ((X - T[:3, 3]) @ T[:3, :3] <= HI), 1)
    live = op > 0.1
    with open(f"{rd}/splat.ply", "wb") as fh:
        fh.write(header.decode().replace(f"element vertex {len(X)}", f"element vertex {keep.sum()}").encode())
        fh.write(np.asarray(v[keep]).tobytes())
    metrics = None
    if os.path.exists(f"{rd}/metrics.csv"):
        last = open(f"{rd}/metrics.csv").read().strip().splitlines()[-1].split(",")
        metrics = dict(iteration=int(last[0]), psnr=float(last[1]), ssim=float(last[2]), gaussians=int(last[4]))
    summary = dict(sfm=json.load(open(f"{work}/sfm_summary.json")),
                   box={k: box.get(k) for k in ("source", "label", "size_m", "lidar_scale", "seed_points", "mask_share_median")},
                   heldout_masked_to_box=metrics, gaussians_kept=int(keep.sum()), gaussians_trained=int(len(X)),
                   opacity_outside_box_before_crop=float(op[live & ~keep].sum() / op[live].sum()))
    json.dump(summary, open(f"{rd}/summary.json", "w"), indent=1)
    print(f"finalize {run}: kept {keep.sum():,} of {len(X):,} Gaussians (opacity outside the box {summary['opacity_outside_box_before_crop']:.1%});"
          f" held-out {metrics['psnr']:.2f} dB / {metrics['ssim']:.3f}" if metrics else "")


if __name__ == "__main__":
    main(*sys.argv[1:3])
