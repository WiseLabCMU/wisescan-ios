"""Stage 3 (CPU, a minute or two): box, per-still masks, depth, prior blanking, seed crop.

    python box_masks.py DUMP OUT

Box: OUT/work/region.json (the capture's focus region) when present; otherwise an automatic box from
the LiDAR (gravity-level, yawed to the walls, a wall face on each side of each axis where one is
found, else the 2nd/98th percentile, floor to ceiling).
For every registered still:
  depth  - its LiDAR resampled into the still's pixel grid at the still focal scale, 16-bit in 0.1 mm
           units (LichtFeld rejects desk-scale millimetres as flat), zeroed outside the box
  mask   - 255 where the still's own LiDAR surface and its 8 neighbours lie inside the box, else 0;
           stills without depth take the nearest surface from the fused LiDAR of the others
  normal - MoGe's normal set to the inactive mid-grey outside the box (depth and normal losses do
           not read masks)
Seed: the model's points inside the box, as sparse/0/points3D.ply (read before points3D.bin).
Writes OUT/work/box.json (read by box_hook.py) and OUT/work/masks_preview.jpg.
"""
import csv
import json
import os
import sys

import cv2
import numpy as np
from PIL import Image
from scipy.spatial.transform import Rotation as Rot

UNITS_PER_MM = 10


def load_model(txt):
    cams = {}
    for line in open(f"{txt}/cameras.txt"):
        if line.startswith("#") or not line.strip():
            continue
        f = line.split()
        cams[int(f[0])] = tuple(map(float, f[4:8]))
    L = [l for l in open(f"{txt}/images.txt") if not l.startswith("#")]
    ims = {}
    for a, b in zip(L[0::2], L[1::2]):
        s = a.split()
        if len(s) < 10:
            continue
        q = np.array(list(map(float, s[1:5])))
        o = np.array(b.split(), float).reshape(-1, 3)
        ims[s[9]] = dict(R=Rot.from_quat([q[1], q[2], q[3], q[0]]).as_matrix(), t=np.array(list(map(float, s[5:8]))),
                         uv=o[o[:, 2] >= 0, :2], pid=o[o[:, 2] >= 0, 2].astype(int))
    pts = {}
    for line in open(f"{txt}/points3D.txt"):
        if line.startswith("#") or not line.strip():
            continue
        p = line.split()
        pts[int(p[0])] = (float(p[1]), float(p[2]), float(p[3]), int(p[4]), int(p[5]), int(p[6]))
    return ims, pts


def depth_cam(r):
    """The LiDAR map's geometry: ARKit's reported intrinsics (the video's, scaled to the still)."""
    return int(r["width"]), int(r["height"]), float(r["fx"]), float(r["fy"]), float(r["cx"]), float(r["cy"])


def backproject(im, d, cam):
    W, H, fx, fy, cx, cy = cam
    h, w = d.shape
    jj, ii = np.mgrid[0:h, 0:w]
    Pc = np.stack([((ii + .5) * W / w - cx) / fx * d, ((jj + .5) * H / h - cy) / fy * d, d], -1)
    return (Pc - im["t"]) @ im["R"]


def still_index(r, h, w, k):
    """Depth-grid row / column for every still row / column through the two geometries."""
    W, H, cx, cy = int(r["width"]), int(r["height"]), float(r["cx"]), float(r["cy"])
    vv = np.clip(((cy + (np.arange(H) + .5 - cy) / k) * h / H).astype(int), 0, h - 1)
    uu = np.clip(((cx + (np.arange(W) + .5 - cx) / k) * w / W).astype(int), 0, w - 1)
    return vv, uu


def lidar_scale(ims, pts, rows, dump):
    """Median LiDAR / model depth on triangulated points: model units follow ARKit's scale."""
    ratios = []
    for n, im in ims.items():
        r = rows[n]
        if not r.get("depth_file"):
            continue
        d = np.asarray(Image.open(f"{dump}/{r['depth_file']}"), np.float64) / 1000
        c = np.asarray(Image.open(f"{dump}/{r['confidence_file']}"))
        X = np.array([pts[p][:3] for p in im["pid"]])
        if not len(X):
            continue
        Xc = X @ im["R"].T + im["t"]
        W, H, fx, fy, cx, cy = depth_cam(r)
        h, w = d.shape
        u = np.floor((fx * Xc[:, 0] / Xc[:, 2] + cx) * w / W).astype(int)
        v = np.floor((fy * Xc[:, 1] / Xc[:, 2] + cy) * h / H).astype(int)
        ok = (u >= 0) & (u < w) & (v >= 0) & (v < h) & (Xc[:, 2] > 0)
        dd, cc = d[v[ok], u[ok]], c[v[ok], u[ok]]
        g = (dd > 0.1) & (cc == 2)
        ratios.append(dd[g] / Xc[ok, 2][g])
    return float(np.median(np.concatenate(ratios))) if ratios else 1.0


def auto_box(P, s):
    """Gravity-level box yawed to the walls, from confident LiDAR P (model units, +Y down)."""
    floor_y = np.percentile(P[:, 1], 99)
    height = (floor_y - P[:, 1]) * s
    walls = P[(height > 1.3) & (height < 2.2)]

    def rot(th):
        c_, s_ = np.cos(th), np.sin(th)
        return np.array([[c_, 0, s_], [0, 1, 0], [-s_, 0, c_]])

    def sharp(th):
        q = walls @ rot(th).T
        return sum(float((np.histogram(q[:, a], bins=np.arange(q[:, a].min(), q[:, a].max() + .02 / s, .02 / s))[0].astype(float) ** 2).sum()) for a in (0, 2))
    th = max(np.radians(np.arange(0, 90, .25)), key=sharp)
    Rb = rot(th)
    Q, Wq = P @ Rb.T, walls @ Rb.T
    lo, hi = np.zeros(3), np.zeros(3)
    for a in (0, 2):
        mid = np.median(Q[:, a])
        for side in (-1, 1):
            part = Wq[(Wq[:, a] - mid) * side > 0, a]
            bound = float(np.percentile(Q[:, a], 98 if side > 0 else 2))
            if len(part) > 200:
                h, e = np.histogram(part, bins=np.arange(part.min(), part.max() + .02 / s, .02 / s))
                if h.max() / len(part) >= 0.08:
                    bound = float((e[np.argmax(h)] + e[np.argmax(h) + 1]) / 2) + side * .05 / s
            (hi if side > 0 else lo)[a] = bound
    inside = (Q[:, 0] >= lo[0]) & (Q[:, 0] <= hi[0]) & (Q[:, 2] >= lo[2]) & (Q[:, 2] <= hi[2])
    lo[1] = floor_y - min(float(np.percentile(height[inside], 99.5)) + .05, 4.0) / s
    hi[1] = floor_y + .05 / s
    T = np.eye(4)
    T[:3, :3] = Rb.T
    return dict(source="auto", label="", box_to_model=T.tolist(), min=lo.tolist(), max=hi.tolist())


def main(dump, out):
    ds, work = f"{out}/dataset", f"{out}/work"
    k = json.load(open(f"{ds}/dataset_transform.json"))["still_focal_scale"]
    rows = {os.path.basename(r["file"]): r for r in csv.DictReader(open(f"{dump}/photos.csv"))}
    ims, pts = load_model(f"{work}/model_txt")
    names = sorted(ims)
    s = lidar_scale(ims, pts, rows, dump)

    lidar = {}
    for n in names:
        r = rows[n]
        if r.get("depth_file"):
            lidar[n] = (np.asarray(Image.open(f"{dump}/{r['depth_file']}"), np.float64),
                        np.asarray(Image.open(f"{dump}/{r['confidence_file']}")))
    if os.path.exists(f"{work}/region.json"):
        box = json.load(open(f"{work}/region.json"))
    else:
        P = np.concatenate([backproject(ims[n], mm / 1000 / s, depth_cam(rows[n]))[c == 2] for n, (mm, c) in lidar.items()])
        box = auto_box(P[(P[:, 2] == P[:, 2])], s)
    T = np.array(box["box_to_model"])
    LO, HI = np.array(box["min"]), np.array(box["max"])

    def in_box(X):
        q = (X - T[:3, 3]) @ T[:3, :3]
        return np.all((q >= LO) & (q <= HI), axis=-1)

    fused = np.concatenate([backproject(ims[n], mm / 1000 / s, depth_cam(rows[n]))[(mm > 100) & (c >= 1)][::4] for n, (mm, c) in lidar.items()]) if lidar else np.zeros((0, 3))
    fused_in = in_box(fused) if len(fused) else np.zeros(0, bool)

    def zbuffer_inside(im, r, h=192, w=256, f=2):
        W, H, fx, fy, cx, cy = depth_cam(r)
        Xc = fused @ im["R"].T + im["t"]
        z = Xc[:, 2]
        ok = z > 0.05
        hh, ww = h // f, w // f
        u = np.floor((fx * Xc[ok, 0] / z[ok] + cx) * ww / W).astype(int)
        v = np.floor((fy * Xc[ok, 1] / z[ok] + cy) * hh / H).astype(int)
        g = (u >= 0) & (u < ww) & (v >= 0) & (v < hh)
        order = np.argsort(-z[ok][g])
        val = np.full(hh * ww, -1, np.int8)
        val[(v[g] * ww + u[g])[order]] = fused_in[ok][g][order].astype(np.int8)
        return np.repeat(np.repeat(val.reshape(hh, ww) != 0, f, 0), f, 1)

    for sub in ("masks", "depth"):
        os.makedirs(f"{ds}/{sub}", exist_ok=True)
    stale = f"{ds}/depth/depth_anchors.json"
    if os.path.exists(stale):
        os.remove(stale)
    have_normals = os.path.isdir(f"{ds}/normals")
    kept, previews = [], []
    for i, n in enumerate(names):
        r, stem = rows[n], os.path.splitext(n)[0]
        if n in lidar:
            mm, c = lidar[n]
            inside = (mm > 0) & in_box(backproject(ims[n], mm / 1000 / s, depth_cam(r)))
        else:
            mm, inside = None, zbuffer_inside(ims[n], r)
        pad = np.pad(inside, 1)
        keep_lo = np.ones_like(inside)
        for dy in range(3):
            for dx in range(3):
                keep_lo &= pad[dy:dy + inside.shape[0], dx:dx + inside.shape[1]]
        vv, uu = still_index(r, *inside.shape, k)
        keep = keep_lo[np.ix_(vv, uu)]
        kept.append(keep.mean())
        Image.fromarray((keep * 255).astype(np.uint8)).save(f"{ds}/masks/{stem}.png", compress_level=1)
        if mm is not None:
            units = np.clip(np.round(mm * UNITS_PER_MM), 0, 65535).astype(np.uint16)[np.ix_(vv, uu)]
            units[~keep] = 0
            Image.fromarray(units).save(f"{ds}/depth/{stem}.png", compress_level=1)
        if have_normals and os.path.exists(f"{ds}/normals/{stem}.png"):
            nrm = cv2.imread(f"{ds}/normals/{stem}.png", cv2.IMREAD_UNCHANGED)
            nk = cv2.resize(keep.astype(np.uint8), (nrm.shape[1], nrm.shape[0]), interpolation=cv2.INTER_NEAREST).astype(bool)
            nrm[~nk] = 32768 if nrm.dtype == np.uint16 else 128
            cv2.imwrite(f"{ds}/normals/{stem}.png", nrm)
        if i % max(1, len(names) // 6) == 0 and len(previews) < 6:
            im = np.asarray(Image.open(f"{ds}/images/{n}").convert("RGB").resize((1008, 756)))
            ks = np.asarray(Image.fromarray((keep * 255).astype(np.uint8)).resize((1008, 756), Image.NEAREST)) > 127
            tint = im.copy()
            tint[~ks] = (im[~ks] * 0.35 + np.array([200, 30, 30]) * 0.65).astype(np.uint8)
            previews.append(np.concatenate([im, tint], 1))
    Image.fromarray(np.concatenate(previews, 0)).save(f"{work}/masks_preview.jpg", quality=82)

    sp = np.array([v for v in pts.values()])
    sp = sp[in_box(sp[:, :3])]
    rec = np.zeros(len(sp), dtype=[("x", "<f4"), ("y", "<f4"), ("z", "<f4"), ("red", "u1"), ("green", "u1"), ("blue", "u1")])
    for j, key in enumerate(("x", "y", "z", "red", "green", "blue")):
        rec[key] = sp[:, j]
    with open(f"{ds}/sparse/0/points3D.ply", "wb") as fh:
        fh.write(("ply\nformat binary_little_endian 1.0\nelement vertex %d\nproperty float x\nproperty float y\nproperty float z\n"
                  "property uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n" % len(rec)).encode())
        fh.write(rec.tobytes())
    box.update(lidar_scale=s, seed_points=int(len(rec)), mask_share_median=float(np.median(kept)))
    json.dump(box, open(f"{work}/box.json", "w"), indent=1)
    cams_in = int(sum(in_box(-ims[n]["R"].T @ ims[n]["t"]) for n in names))
    print(f"box ({box['source']} {box.get('label', '')}): size {np.round((HI - LO) * s, 2).tolist()} m; LiDAR scale {s:.3f};"
          f" masks keep median {np.median(kept):.0%} of a still (min {np.min(kept):.0%}, max {np.max(kept):.0%});"
          f" seed {len(rec):,} points; cameras inside the box {cams_in}/{len(names)}; normals {'blanked' if have_normals else 'MISSING'}")


if __name__ == "__main__":
    main(*sys.argv[1:3])
