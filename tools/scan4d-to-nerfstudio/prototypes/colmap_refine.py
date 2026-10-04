"""Step 1 of the pose refit: triangulate COLMAP points with the ARKit poses held FIXED.

features (SIFT, max 1600 px, GPU) -> pose-neighbour matching (pairs chosen from the ARKit poses:
< 3 m apart, < 75 deg view difference, 30 nearest per image) -> point_triangulator with the ARKit
poses and intrinsics fixed. Writes <work>/tri as a TXT model and prints its reprojection error
(how well ARKit's poses already agree with the images).

It deliberately stops there. A free bundle adjustment drifts (about 4% scale plus slow bending on
35B52835) and would fight the metric depth maps and the seed. Step 2, refine_perimage.py, refits
each frame alone against these fixed points instead.

usage: colmap_refine.py <bundle> <work_dir>        (then: refine_perimage.py <work_dir> ...)
Needs COLMAP >= 3.9 on PATH (nerfstudio:blackwell ships 3.11.1 with CUDA). About 3 minutes for
457 frames, GPU only during feature extraction and matching.
"""
import json, sqlite3, subprocess, sys, time
from pathlib import Path
import numpy as np

bundle, work = Path(sys.argv[1]), Path(sys.argv[2])
work.mkdir(parents=True, exist_ok=True); db = work / "database.db"; img = bundle / "images"
timings = {}


def run(step, *args):
    t = time.time(); r = subprocess.run(["colmap", *args], capture_output=True, text=True)
    (work / f"{step}.log").write_text(r.stdout + r.stderr); timings[step] = time.time() - t
    if r.returncode:
        sys.exit(f"{step} failed, see {work}/{step}.log")


def qvec(R):
    w = np.sqrt(max(0, 1 + np.trace(R))) / 2
    return np.array([w, (R[2, 1] - R[1, 2]) / (4 * w), (R[0, 2] - R[2, 0]) / (4 * w), (R[1, 0] - R[0, 1]) / (4 * w)])


T = json.load(open(bundle / "transforms.json")); F = {f["file_path"].split("/")[-1]: f for f in T["frames"]}
if db.exists():
    db.unlink()
run("features", "feature_extractor", "--database_path", str(db), "--image_path", str(img),
    "--ImageReader.camera_model", "PINHOLE", "--ImageReader.single_camera", "0",
    "--SiftExtraction.max_image_size", "1600", "--SiftExtraction.max_num_features", "8192",
    "--SiftExtraction.use_gpu", "1")

# Known model: ARKit intrinsics and poses (ARKit/OpenGL c2w -> COLMAP OpenCV w2c).
con = sqlite3.connect(db); ids = {n: (i, c) for i, n, c in con.execute("SELECT image_id, name, camera_id FROM images")}
D = np.diag([1.0, -1.0, -1.0, 1.0])
known = work / "known"; known.mkdir(exist_ok=True)
cams, imgs, centers, dirs, names = [], [], [], [], []
for name, (iid, cid) in sorted(ids.items(), key=lambda kv: kv[1][0]):
    if name not in F:
        continue
    f = F[name]; p = np.array([f["fl_x"], f["fl_y"], f["cx"], f["cy"]], np.float64)
    con.execute("UPDATE cameras SET model=1, width=?, height=?, params=?, prior_focal_length=1 WHERE camera_id=?",
                (f["w"], f["h"], p.tobytes(), cid))
    c2w = np.array(f["transform_matrix"], float) @ D; w2c = np.linalg.inv(c2w)
    q, t = qvec(w2c[:3, :3]), w2c[:3, 3]
    cams.append(f"{cid} PINHOLE {f['w']} {f['h']} {p[0]} {p[1]} {p[2]} {p[3]}")
    imgs.append(f"{iid} {' '.join(map(str, q))} {' '.join(map(str, t))} {cid} {name}\n")
    centers.append(c2w[:3, 3]); dirs.append(c2w[:3, 2]); names.append(name)
con.commit(); con.close()
(known / "cameras.txt").write_text("\n".join(cams) + "\n")
(known / "images.txt").write_text("\n".join(imgs))
(known / "points3D.txt").write_text("")

# Match only pose neighbours instead of all pairs.
C, Dv = np.array(centers), np.array(dirs); pairs = set()
for i in range(len(names)):
    dist = np.linalg.norm(C - C[i], axis=1); ang = np.degrees(np.arccos(np.clip(Dv @ Dv[i], -1, 1)))
    ok = np.where((dist < 3.0) & (ang < 75) & (np.arange(len(names)) != i))[0]
    for j in ok[np.argsort(dist[ok] + ang[ok] / 60)][:30]:
        pairs.add(tuple(sorted((names[i], names[j]))))
(work / "pairs.txt").write_text("\n".join(f"{a} {b}" for a, b in sorted(pairs)) + "\n")
run("matching", "matches_importer", "--database_path", str(db), "--match_list_path", str(work / "pairs.txt"),
    "--match_type", "pairs", "--SiftMatching.use_gpu", "1")

tri = work / "tri"; tri.mkdir(exist_ok=True)
run("triangulate", "point_triangulator", "--database_path", str(db), "--image_path", str(img),
    "--input_path", str(known), "--output_path", str(tri),
    "--Mapper.ba_refine_focal_length", "0", "--Mapper.ba_refine_principal_point", "0",
    "--Mapper.ba_refine_extra_params", "0")
subprocess.run(["colmap", "model_converter", "--input_path", str(tri), "--output_path", str(tri),
                "--output_type", "TXT"], capture_output=True)

r = subprocess.run(["colmap", "model_analyzer", "--path", str(tri)], capture_output=True, text=True)
keep = ("Registered images", "Points", "Observations", "Mean track length", "Mean reprojection error")
stats = {k.strip(): v.strip() for k, v in (l.split("]")[-1].split(":", 1) for l in (r.stdout + r.stderr).splitlines() if ":" in l)
         if k.strip() in keep}
print(f"pairs {len(pairs)}; triangulated with ARKit poses fixed: " + "; ".join(f"{k} {v}" for k, v in stats.items()))
print("timings (s): " + ", ".join(f"{k} {v:.0f}" for k, v in timings.items()) + f"; total {sum(timings.values()) / 60:.1f} min")
print(f"next: refine_perimage.py {work} {bundle / 'transforms.json'} <out transforms.json>")
