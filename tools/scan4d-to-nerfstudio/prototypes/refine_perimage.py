"""Step 2 of the pose refit: drift-free per-frame refinement.

The 3D points that colmap_refine.py triangulated with the ARKit poses held fixed (<work>/tri) stay
fixed; each frame's pose alone is re-fitted to them (Huber least squares). No global drift, so
the result stays consistent with the metric depth maps and the seed. Frames with fewer than 30
observations keep their ARKit pose.

usage: refine_perimage.py <work_dir> <bundle>/transforms.json <out transforms.json>
Write the output into a copy of the bundle (hard-link images/depth/normals), never over the export.
"""
import json, sys, time
from pathlib import Path
import numpy as np
from scipy.optimize import least_squares
from scipy.spatial.transform import Rotation as Rot
work, src_json, out_json = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
t0 = time.time(); model = work / "tri"
cams = {int(l.split()[0]): list(map(float, l.split()[4:8])) for l in (model / "cameras.txt").read_text().splitlines() if l and not l.startswith("#")}
pts = {int(l.split()[0]): np.array(list(map(float, l.split()[1:4]))) for l in (model / "points3D.txt").read_text().splitlines() if l and not l.startswith("#")}
L = [l for l in (model / "images.txt").read_text().splitlines() if not l.startswith("#")]
T = json.load(open(src_json)); F = {f["file_path"].split("/")[-1]: f for f in T["frames"]}; D = np.diag([1.0, -1.0, -1.0, 1.0])
rows = []
for a, b in zip(L[0::2], L[1::2]):
    s = a.split(); name, cid = s[9], int(s[8]); o = np.array(b.split(), float).reshape(-1, 3) if b.split() else np.zeros((0, 3))
    o = o[[int(i) in pts for i in o[:, 2]]] if len(o) else o
    if len(o) < 30 or name not in F: continue
    X = np.array([pts[int(i)] for i in o[:, 2]]); uv = o[:, :2]; fx, fy, cx, cy = cams[cid]
    w2c0 = np.linalg.inv(np.array(F[name]["transform_matrix"], float) @ D); R0, t0v = w2c0[:3, :3], w2c0[:3, 3]
    def res(p):
        R = Rot.from_rotvec(p[:3]).as_matrix() @ R0; pc = X @ R.T + (t0v + p[3:])
        return np.concatenate([fx * pc[:, 0] / pc[:, 2] + cx - uv[:, 0], fy * pc[:, 1] / pc[:, 2] + cy - uv[:, 1]])
    e0 = np.hypot(*res(np.zeros(6)).reshape(2, -1))
    sol = least_squares(res, np.zeros(6), loss="huber", f_scale=1.5, x_scale=[1e-3] * 3 + [1e-3] * 3)
    e1 = np.hypot(*sol.fun.reshape(2, -1)) if False else np.hypot(*res(sol.x).reshape(2, -1))
    R = Rot.from_rotvec(sol.x[:3]).as_matrix() @ R0; t = t0v + sol.x[3:]
    w2c = np.eye(4); w2c[:3, :3], w2c[:3, 3] = R, t; c2w = np.linalg.inv(w2c)
    ang = np.degrees(np.linalg.norm(sol.x[:3])); dc = np.linalg.norm(c2w[:3, 3] - np.linalg.inv(w2c0)[:3, 3]) * 100
    F[name]["transform_matrix"] = (c2w @ D).tolist()
    rows.append((name, ang, dc, np.radians(ang) * fx, float(np.median(e0)), float(np.median(e1)), bool(F[name].get("is_keyframe"))))
T["pose_refine"] = f"per-frame pose refit against COLMAP points triangulated with ARKit poses fixed (no global drift); {len(rows)} of {len(F)} frames"
json.dump(T, open(out_json, "w"), indent=2)
a = np.array([r[1] for r in rows]); dc = np.array([r[2] for r in rows]); px = np.array([r[3] for r in rows]); e0 = np.array([r[4] for r in rows]); e1 = np.array([r[5] for r in rows]); st = np.array([r[6] for r in rows])
print(f"refitted {len(rows)} frames in {time.time() - t0:.0f} s")
print(f"correction: rotation median {np.median(a):.3f} deg (p90 {np.percentile(a, 90):.3f}, max {a.max():.3f}), position median {np.median(dc):.2f} cm (p90 {np.percentile(dc, 90):.2f}), image shift median {np.median(px):.1f} px (p90 {np.percentile(px, 90):.1f}); stills {np.median(px[st]):.1f} px, stream {np.median(px[~st]):.1f} px")
print(f"per-frame median reprojection error: {np.median(e0):.2f} -> {np.median(e1):.2f} px (p90 {np.percentile(e0, 90):.2f} -> {np.percentile(e1, 90):.2f})")
top = np.argsort(-px)[:8]; print("largest corrections:", ", ".join(f"{rows[i][0][6:11]}{'S' if st[i] else ''} {px[i]:.1f}px" for i in top))
