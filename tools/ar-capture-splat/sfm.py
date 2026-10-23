"""Stage 2 (GPU features + matching, CPU mapping): poses from the stills with ARKit as priors.

    python sfm.py OUT [--pairs rule|topkN]

SIFT on every still (3200 px, up to 16k features), matched only on pairs chosen from ARKit's
poses, then COLMAP pose_prior_mapper with ARKit's camera centres as 3 cm robust priors, so the
result stays in ARKit's frame and scale while the images fix the rotations. Intrinsics are fixed at
the corrected still focal; for a device with no known scale they are refined and the median
refined / reported ratio is written back to dataset_transform.json.

Writes OUT/work/model_txt (poses + points, TXT), OUT/dataset/sparse/0 (BIN, what LichtFeld reads).
"""
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import time

import numpy as np

PAIR_MAX_DIST_M, PAIR_MAX_AXIS_DEG, PAIR_TEMPORAL = 2.5, 75.0, 5
PRIOR_STD_M = 0.03


def q2R(q):
    w, x, y, z = q
    return np.array([[1 - 2 * y * y - 2 * z * z, 2 * x * y - 2 * w * z, 2 * x * z + 2 * w * y],
                     [2 * x * y + 2 * w * z, 1 - 2 * x * x - 2 * z * z, 2 * y * z - 2 * w * x],
                     [2 * x * z - 2 * w * y, 2 * y * z + 2 * w * x, 1 - 2 * x * x - 2 * y * y]])


def run(log, *args):
    with open(log, "a") as fh:
        fh.write("+ " + " ".join(args) + "\n")
        fh.flush()
        subprocess.run(args, check=True, stdout=fh, stderr=subprocess.STDOUT)


def known(work):
    cams = {}
    for line in open(f"{work}/known/cameras.txt"):
        f = line.split()
        if len(f) >= 8:
            cams[int(f[0])] = (int(f[2]), int(f[3]), tuple(map(float, f[4:8])))
    out = {}
    for line in open(f"{work}/known/images.txt"):
        f = line.split()
        if len(f) < 10:
            continue
        R, t = q2R(list(map(float, f[1:5]))), np.array(list(map(float, f[5:8])))
        w, h, k = cams[int(f[8])]
        out[f[9]] = dict(C=-R.T @ t, fwd=R.T @ np.array([0, 0, 1.0]), k=k, w=w, h=h)
    return out


def pairs_for(cams, mode):
    names = sorted(cams)
    C = np.array([cams[n]["C"] for n in names])
    Fw = np.array([cams[n]["fwd"] for n in names])
    dist = np.linalg.norm(C[:, None] - C[None], axis=2)
    ang = np.degrees(np.arccos(np.clip(Fw @ Fw.T, -1, 1)))
    ok = (dist < PAIR_MAX_DIST_M) & (ang < PAIR_MAX_AXIS_DEG)
    pairs = set()
    if mode.startswith("topk"):
        k = int(mode[4:])
        score = np.where(ok, dist / PAIR_MAX_DIST_M + ang / PAIR_MAX_AXIS_DEG, np.inf)
        np.fill_diagonal(score, np.inf)
        for i in range(len(names)):
            for j in np.argsort(score[i])[:k]:
                if np.isfinite(score[i, j]):
                    pairs.add(tuple(sorted((names[i], names[j]))))
    else:
        for i in range(len(names)):
            for j in range(i + 1, len(names)):
                if ok[i, j]:
                    pairs.add((names[i], names[j]))
    for i in range(len(names)):
        for j in range(i + 1, min(len(names), i + PAIR_TEMPORAL + 1)):
            pairs.add((names[i], names[j]))
    return sorted(pairs)


def main(out, mode):
    work, ds = f"{out}/work", f"{out}/dataset"
    log = f"{work}/colmap.log"
    tf = json.load(open(f"{ds}/dataset_transform.json"))
    refine_focal = tf.get("still_focal_scale") is None
    cams = known(work)
    db = f"{work}/database.db"
    for p in (db, db + "-journal", db + "-wal", db + "-shm"):
        if os.path.exists(p):
            os.remove(p)
    t0 = time.time()
    run(log, "colmap", "feature_extractor", "--database_path", db, "--image_path", f"{ds}/images",
        "--ImageReader.camera_model", "PINHOLE", "--ImageReader.single_camera_per_image", "1",
        "--SiftExtraction.max_image_size", "3200", "--SiftExtraction.max_num_features", "16384")
    t1 = time.time()
    con = sqlite3.connect(db)
    for image_id, name, camera_id in con.execute("SELECT image_id, name, camera_id FROM images").fetchall():
        c = cams[name]
        con.execute("UPDATE cameras SET model=1, width=?, height=?, params=?, prior_focal_length=1 WHERE camera_id=?",
                    (c["w"], c["h"], np.array(c["k"], np.float64).tobytes(), camera_id))
        con.execute("INSERT OR REPLACE INTO pose_priors VALUES (?, ?, ?, ?)",
                    (image_id, np.asarray(c["C"], np.float64).tobytes(), 1, (np.eye(3) * PRIOR_STD_M ** 2).tobytes()))
    con.commit()
    con.close()
    pairs = pairs_for(cams, mode)
    with open(f"{work}/pairs.txt", "w") as fh:
        fh.writelines(f"{a} {b}\n" for a, b in pairs)
    run(log, "colmap", "matches_importer", "--database_path", db, "--match_list_path", f"{work}/pairs.txt",
        "--match_type", "pairs", "--SiftMatching.guided_matching", "1")
    t2 = time.time()
    sparse = f"{work}/sparse"
    shutil.rmtree(sparse, ignore_errors=True)
    os.makedirs(sparse)
    run(log, "colmap", "pose_prior_mapper", "--database_path", db, "--image_path", f"{ds}/images", "--output_path", sparse,
        "--Mapper.ba_refine_focal_length", "1" if refine_focal else "0", "--Mapper.ba_refine_principal_point", "0",
        "--Mapper.ba_refine_extra_params", "0",
        "--prior_position_std_x", str(PRIOR_STD_M), "--prior_position_std_y", str(PRIOR_STD_M),
        "--prior_position_std_z", str(PRIOR_STD_M), "--overwrite_priors_covariance", "1",
        "--use_robust_loss_on_prior_position", "1")
    t3 = time.time()
    best = max(os.listdir(sparse), key=lambda m: os.path.getsize(f"{sparse}/{m}/images.bin"))
    txt = f"{work}/model_txt"
    shutil.rmtree(txt, ignore_errors=True)
    os.makedirs(txt)
    run(log, "colmap", "model_converter", "--input_path", f"{sparse}/{best}", "--output_path", txt, "--output_type", "TXT")
    shutil.rmtree(f"{ds}/sparse", ignore_errors=True)
    os.makedirs(f"{ds}/sparse/0")
    run(log, "colmap", "model_converter", "--input_path", f"{sparse}/{best}", "--output_path", f"{ds}/sparse/0", "--output_type", "BIN")

    reg = [l for l in open(f"{txt}/images.txt") if not l.startswith("#")][0::2]
    reg = [l for l in reg if len(l.split()) >= 10]
    errs, tracks = [], []
    for l in open(f"{txt}/points3D.txt"):
        if l.startswith("#") or not l.strip():
            continue
        p = l.split()
        errs.append(float(p[7]))
        tracks.append((len(p) - 8) // 2)
    if refine_focal:
        solved = {int(l.split()[0]): float(l.split()[4]) for l in open(f"{txt}/cameras.txt") if l.strip() and not l.startswith("#")}
        names = {int(l.split()[8]): l.split()[9] for l in reg}
        ratio = float(np.median([solved[c] / cams[names[c]]["k"][0] for c in solved if c in names]))
        tf["still_focal_scale"] = ratio
        tf["still_focal_scale_source"] = "solved per scan (device not in DEVICE_FOCAL)"
        json.dump(tf, open(f"{ds}/dataset_transform.json", "w"), indent=1)
    summary = dict(registered=len(reg), stills=len(cams), pairs=len(pairs), points=len(tracks),
                   mean_track=float(np.mean(tracks)), tracks_3plus=float(np.mean(np.array(tracks) >= 3)),
                   reprojection_px=float(np.mean(errs)), still_focal_scale=tf["still_focal_scale"],
                   minutes=dict(features=round((t1 - t0) / 60, 2), matching=round((t2 - t1) / 60, 2), mapping=round((t3 - t2) / 60, 2)))
    json.dump(summary, open(f"{work}/sfm_summary.json", "w"), indent=1)
    print(f"sfm: {summary['registered']}/{summary['stills']} registered, {summary['points']:,} points, track {summary['mean_track']:.2f},"
          f" 3+ {summary['tracks_3plus']:.0%}, {summary['reprojection_px']:.2f} px, {len(pairs)} pairs, focal scale {summary['still_focal_scale']:.4f};"
          f" features {summary['minutes']['features']} min, matching {summary['minutes']['matching']} min, mapping {summary['minutes']['mapping']} min")


if __name__ == "__main__":
    args = sys.argv[1:]
    mode = args[args.index("--pairs") + 1] if "--pairs" in args else "rule"
    main(args[0], mode)
