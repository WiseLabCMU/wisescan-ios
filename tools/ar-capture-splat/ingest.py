"""Stage 1 (CPU, seconds): AR Capture dump -> dataset images, ARKit pose priors, box.

    python ingest.py DUMP OUT

Writes
  OUT/dataset/images/                  the stills, as captured
  OUT/dataset/dataset_transform.json   arkit -> dataset transform, still focal scale, device
  OUT/work/known/{cameras,images,points3D}.txt   ARKit poses in the dataset frame (pose priors, pairs)
  OUT/work/region.json                 the focus box in the dataset frame, when the dump has one

Frame: dataset = F (arkit - c), F = diag(1, -1, -1) (gravity to +Y, the COLMAP convention), with c the
focus region's centre when there is one, else the point closest to every camera's optical axis.
Still focal: ARKit reports the video's intrinsics scaled to the still; the true still focal is a
per-device constant (DEVICE_FOCAL). An unknown device gets None here and sfm.py solves it.
"""
import csv
import json
import os
import shutil
import sys

import numpy as np

# Still focal / ARKit-reported focal, measured per device (see the WIP pipeline doc).
DEVICE_FOCAL = {"iPad13,9": 1.0476, "iPhone18,1": 1.0136}
F = np.diag([1.0, -1.0, -1.0])


def rot2q(R):
    w = np.sqrt(max(0, 1 + R[0, 0] + R[1, 1] + R[2, 2])) / 2
    x = np.copysign(np.sqrt(max(0, 1 + R[0, 0] - R[1, 1] - R[2, 2])) / 2, R[2, 1] - R[1, 2])
    y = np.copysign(np.sqrt(max(0, 1 - R[0, 0] + R[1, 1] - R[2, 2])) / 2, R[0, 2] - R[2, 0])
    z = np.copysign(np.sqrt(max(0, 1 - R[0, 0] - R[1, 1] + R[2, 2])) / 2, R[1, 0] - R[0, 1])
    q = np.array([w, x, y, z])
    return q / np.linalg.norm(q)


def main(dump, out):
    setup = json.load(open(f"{dump}/manifest.json"))["setup"]
    rows = sorted(csv.DictReader(open(f"{dump}/photos.csv")), key=lambda r: r["file"])
    device = setup.get("deviceModel", "")
    scale = DEVICE_FOCAL.get(device)
    for d in ("dataset/images", "work/known"):
        os.makedirs(f"{out}/{d}", exist_ok=True)

    c2w = []
    for r in rows:
        m = np.eye(4)
        m[:3, :4] = np.array([float(r[f"c2w_{i}{j}"]) for i in range(3) for j in range(4)]).reshape(3, 4)
        c2w.append(m @ np.diag([1.0, -1.0, -1.0, 1.0]))      # ARKit camera axes -> OpenCV
    c2w = np.array(c2w)

    region = None
    if setup.get("regionToWorld") and setup.get("focusRegion"):
        Tr = np.array(setup["regionToWorld"], float).reshape(4, 4).T     # column-major in the manifest
        size = np.array(setup["focusRegion"]["size_m"], float)
        region = (Tr, size, setup["focusRegion"].get("label", ""))
        c = Tr[:3, 3]
    else:
        A, b = np.zeros((3, 3)), np.zeros(3)
        for m in c2w:
            d = m[:3, 2]
            P = np.eye(3) - np.outer(d, d)
            A += P
            b += P @ m[:3, 3]
        c = np.linalg.solve(A, b)

    T = np.eye(4)
    T[:3, :3] = F
    T[:3, 3] = -F @ c
    json.dump({"arkit_to_dataset": T.tolist(), "origin_arkit": c.tolist(), "still_focal_scale": scale,
               "device": device, "origin": "focus region centre" if region else "optical-axis point"},
              open(f"{out}/dataset/dataset_transform.json", "w"), indent=1)

    for r in rows:
        shutil.copyfile(f"{dump}/{r['file']}", f"{out}/dataset/images/{os.path.basename(r['file'])}")

    k = scale or 1.0
    with open(f"{out}/work/known/cameras.txt", "w") as fc, open(f"{out}/work/known/images.txt", "w") as fi:
        for i, (r, m) in enumerate(zip(rows, c2w), 1):
            fc.write(f"{i} PINHOLE {r['width']} {r['height']} {float(r['fx']) * k:.4f} {float(r['fy']) * k:.4f} {r['cx']} {r['cy']}\n")
            Rd, td = F @ m[:3, :3], F @ (m[:3, 3] - c)          # dataset camera-to-world
            Rw, tw = Rd.T, -Rd.T @ td                          # COLMAP world-to-camera
            q = rot2q(Rw)
            fi.write(f"{i} {' '.join(f'{v:.12f}' for v in q)} {' '.join(f'{v:.9f}' for v in tw)} {i} {os.path.basename(r['file'])}\n\n")
    open(f"{out}/work/known/points3D.txt", "w").close()

    if region:
        Tr, size, label = region
        Tb = np.eye(4)
        Tb[:3, :3] = F @ Tr[:3, :3]
        Tb[:3, 3] = F @ (Tr[:3, 3] - c)
        json.dump({"source": "focus_region", "label": label, "box_to_model": Tb.tolist(),
                   "min": (-size / 2).tolist(), "max": (size / 2).tolist(), "size_m": size.tolist()},
                  open(f"{out}/work/region.json", "w"), indent=1)

    with_depth = sum(1 for r in rows if r.get("depth_file"))
    print(f"ingest: {len(rows)} stills ({with_depth} with depth), device {device or 'unknown'}, still focal scale "
          f"{scale if scale else 'unknown -> solved in sfm'}, box {'from focus region ' + repr(region[2]) + ' ' + str(np.round(region[1], 2).tolist()) + ' m' if region else 'auto (no focus region)'}")


if __name__ == "__main__":
    main(*sys.argv[1:3])
