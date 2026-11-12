"""AGS-Mesh-style depth mask: keep a LiDAR depth pixel only if ARKit rates it high confidence (2)
AND the surface normal implied by the LiDAR agrees with MoGe's normal within ANGLE degrees.
Works on the native 256x192 LiDAR grid (the exported depth is nearest-upsampled from it), writes
full-resolution depth PNGs with dropped pixels set to 0 (LichtFeld skips zero depth)."""
import json, sys, time
from pathlib import Path
import numpy as np
from PIL import Image
from scipy.ndimage import uniform_filter
src, dst = Path(sys.argv[1]), Path(sys.argv[2]); ANGLE = float(sys.argv[3]); MINCONF = int(sys.argv[4]); MESH = sys.argv[5] if len(sys.argv) > 5 else None; MESH_ANGLE = 20.0
from scipy.spatial import cKDTree
if MESH:
    _V, _F = [], []
    for _l in open(MESH):
        if _l.startswith("v "): _V.append(_l.split()[1:4])
        elif _l.startswith("f "): _F.append([int(t.split("/")[0]) - 1 for t in _l.split()[1:4]])
    _V = np.array(_V, float); _F = np.array(_F); _fn = np.cross(_V[_F[:, 1]] - _V[_F[:, 0]], _V[_F[:, 2]] - _V[_F[:, 0]])
    VN = np.zeros_like(_V); [np.add.at(VN, _F[:, k], _fn) for k in range(3)]; VN /= np.linalg.norm(VN, axis=1, keepdims=True) + 1e-12
    MTREE = cKDTree(_V)
def lidar_normals(P, valid, k=5):
    w = valid.astype(np.float64); n = uniform_filter(w, k) + 1e-9
    m = [uniform_filter(P[..., i] * w, k) / n for i in range(3)]
    C = np.empty(P.shape[:2] + (3, 3))
    for i in range(3):
        for j in range(i, 3):
            C[..., i, j] = C[..., j, i] = uniform_filter(P[..., i] * P[..., j] * w, k) / n - m[i] * m[j]
    _, vec = np.linalg.eigh(C); N = vec[..., :, 0]
    N *= np.where((N * P).sum(-1, keepdims=True) > 0, -1.0, 1.0)         # face the camera
    ok = valid & (uniform_filter(w, k) > 0.6)                               # enough valid neighbours
    return N, ok
T = json.load(open(src / "transforms.json")); (dst / "depth").mkdir(parents=True, exist_ok=True)
t0 = time.time(); stats = np.zeros(5); sign = None; per = []
for f in sorted(T["frames"], key=lambda f: f["file_path"]):
    name = Path(f["file_path"]).stem
    d = np.asarray(Image.open(src / f["depth_file_path"])); H, W = d.shape
    c = np.asarray(Image.open(src / f["confidence_file_path"])); c = c[..., 0] if c.ndim == 3 else c; ch, cw = c.shape
    jj, ii = np.mgrid[0:ch, 0:cw]; U = ((ii + .5) * W / cw).astype(int); V = ((jj + .5) * H / ch).astype(int)
    z = d[V, U].astype(np.float64) * 0.001; valid = z > 0
    P = np.stack([(U + .5 - f["cx"]) / f["fl_x"] * z, (V + .5 - f["cy"]) / f["fl_y"] * z, z], -1)   # OpenCV camera
    N, okn = lidar_normals(P, valid)
    mg = np.asarray(Image.open(src / "normals" / f"{name}.png").convert("RGB").resize((cw, ch), Image.BOX), np.float64) / 127.5 - 1
    mg /= np.linalg.norm(mg, axis=-1, keepdims=True) + 1e-9
    if sign is None:   # pick MoGe's axis convention by agreement on the first frame
        cands = {"as-is": mg, "flip-yz": mg * [1, -1, -1]}
        score = {k: np.nanmedian(np.abs((v * N).sum(-1))[okn & (c == 2)] * np.sign((v * N).sum(-1))[okn & (c == 2)]) for k, v in cands.items()}
        sign = max(score, key=score.get); print("MoGe convention:", sign, {k: round(float(s), 3) for k, s in score.items()})
    if sign == "flip-yz": mg = mg * [1, -1, -1]
    ang = np.degrees(np.arccos(np.clip((mg * N).sum(-1), -1, 1)))
    rescue = np.zeros_like(valid)
    if MESH:
        M4 = np.array(f["transform_matrix"], float); Rcv = M4[:3, :3] @ np.diag([1.0, -1.0, -1.0])
        q = okn & (ang > ANGLE); Pw = P[q] @ Rcv.T + M4[:3, 3]; dist, idx = MTREE.query(Pw)
        mn = VN[idx] @ Rcv; mn *= np.where((mn * P[q]).sum(-1, keepdims=True) > 0, -1, 1)
        am = np.degrees(np.arccos(np.clip((mn * N[q]).sum(-1), -1, 1))); r = np.zeros(q.sum(), bool); r[(dist < 0.05) & (am <= MESH_ANGLE)] = True
        rescue[q] = r
    keep = valid & (c >= MINCONF) & (~okn | (ang <= ANGLE) | rescue)
    full = keep[(np.arange(H)[:, None] * ch // H), (np.arange(W)[None, :] * cw // W)]
    out = np.where(full & (d > 0), d, 0).astype(np.uint16)
    Image.fromarray(out).save(dst / f["depth_file_path"], compress_level=1)
    stats += [valid.sum(), (valid & (c >= MINCONF)).sum(), (valid & (c >= MINCONF) & okn & (ang > ANGLE)).sum(), keep.sum(), (valid & (c >= MINCONF) & rescue).sum()]
    per.append((name, keep.sum() / max(valid.sum(), 1)))
print(f"{len(per)} depth maps in {time.time() - t0:.0f} s")
print(f"of valid LiDAR pixels: confidence >= MINCONF {stats[1] / stats[0]:.1%}; disagree with MoGe {stats[2] / stats[0]:.1%}, of which rescued by the mesh {stats[4] / stats[0]:.1%}; kept {stats[3] / stats[0]:.1%}")
k = np.array([p[1] for p in per]); print(f"per-frame kept share: median {np.median(k):.1%}, p10 {np.percentile(k, 10):.1%}, min {k.min():.1%}")
