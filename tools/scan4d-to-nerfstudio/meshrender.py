#!/usr/bin/env python3
"""Render per-frame normal maps (and depth) from the ARKit dense mesh.

Prototype for the eventual on-device pass. LichtFeld Studio has a full normal-supervision
stack (--use-normal-loss, --normal-consistency-weight, --normal-flatten-weight) that, when
no normal maps are present, falls back to *estimating* them per image with MoGe — a
monocular network (normal_auto_generate.cpp). We carry the measured ARKit mesh; rendering
it gives metric, multi-view-consistent normals instead, and covers the 360-rig faces too.

Output contract, verified against LichtFeld commit 239b0336:
- ``normals/<image-stem>.png``, 8-bit RGB, exactly the image's WxH. blender_loader.cpp
  attaches sidecars by image-name lookup in a ``normal``/``normals`` folder and enforces
  size equality (NORMAL_SIZE_MISMATCH).
- Encoding ``v = n*0.5 + 0.5`` (Camera::load_and_get_normal decodes ``v*2 - 1``).
- World-space vectors, flipped per frame to face the camera: the loss is ``(1 - cos)``
  (normal_loss.cu), so sign matters. Train with ``--use-normal-loss
  --normal-loss-space world`` (the auto-resolver probes axis permutations; forcing world
  keeps it deterministic).
- No-hit pixels encode ``(128,128,128)`` -> decoded norm ~0.007, far below
  kNormalLossMinPriorNorm = 0.5, so the pixel is inactive. Same skip-the-zeros pattern
  the depth fillers rely on.
- Depth: 16-bit grey PNG, millimetres, big-endian (standard PNG), zero = no supervision.
  Default mode ``missing`` fills only the all-zero filler maps (the rig faces, which
  currently train with no geometric supervision at all) and leaves measured LiDAR depth
  alone.

Needs numpy + open3d (RaycastingScene) + PIL — all present in the nerfstudio image:

  docker run --rm -v /mnt/d/Workspace/WiseLab:/ws nerfstudio:blackwell \\
    python /ws/wisescan-ios/tools/scan4d-to-nerfstudio/meshrender.py \\
    /ws/4dscans/staging_X/both --mesh /ws/4dscans/staging_X/mesh.obj

The mesh must be the OBJ export of the *same scan* (app export format "OBJ"): it is baked
in ARKit world coordinates, the same frame as every camera pose, so no alignment step.
A sanity check compares the mesh AABB against the camera track and aborts on disjoint
geometry (wrong scan / wrong session).
"""

from __future__ import annotations

import argparse
import json
import math
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pngio import write_png8_rgb, write_png16_gray  # noqa: E402

try:
    import numpy as np
    import open3d as o3d
except ImportError as exc:  # pragma: no cover
    sys.exit(f"meshrender needs numpy and open3d (run inside the nerfstudio image): {exc}")

try:
    from PIL import Image
except ImportError:
    Image = None

from fillholes import (accumulate_evidence, build_ceiling, build_floor, build_patches,  # noqa: E402
                       debias, load_face_classes, load_roomplan, transform_planes)

RAY_CHUNK = 4_000_000  # rays per cast_rays call, bounds peak memory
BIAS_FRAME_STRIDE = 13  # every Nth LiDAR frame feeds the bias measurement
EVIDENCE_STRIDE = 4     # LiDAR pixel stride for the hole-fill evidence pass


def load_frames(root: Path):
    meta = json.loads((root / "transforms.json").read_text())
    frames = meta.get("frames", [])
    if not frames:
        sys.exit(f"no frames in {root}/transforms.json")
    return meta, frames


def intrinsics(frame: dict, meta: dict):
    """Per-frame first, then the global block — mixed-camera datasets have no globals."""
    def g(k):
        v = frame.get(k, meta.get(k))
        if v is None:
            sys.exit(f"intrinsic '{k}' missing for {frame.get('file_path')}")
        return v
    return (float(g("fl_x")), float(g("fl_y")), float(g("cx")), float(g("cy")),
            int(g("w")), int(g("h")))


def load_mesh(mesh_path: Path):
    mesh = o3d.io.read_triangle_mesh(str(mesh_path))
    tris = np.asarray(mesh.triangles)
    verts = np.asarray(mesh.vertices)
    if len(tris) == 0:
        sys.exit(f"{mesh_path}: no triangles (not a mesh, or parse failed)")
    lo, hi = verts.min(axis=0), verts.max(axis=0)
    print(f"mesh: {len(verts):,} verts / {len(tris):,} tris, "
          f"AABB [{lo[0]:.1f},{lo[1]:.1f},{lo[2]:.1f}]..[{hi[0]:.1f},{hi[1]:.1f},{hi[2]:.1f}] m")
    return mesh, (lo, hi)


def make_scene_ids(*meshes):
    """Scene plus the geometry id of each (non-empty) mesh, in order — ids let a render
    treat some geometry as normals-only (see render_frame `depthless_ids`)."""
    scene = o3d.t.geometry.RaycastingScene()
    ids = []
    for m in meshes:
        if m is not None and len(m.triangles):
            ids.append(scene.add_triangles(o3d.t.geometry.TriangleMesh.from_legacy(m)))
        else:
            ids.append(None)
    return scene, ids


def make_scene(*meshes):
    return make_scene_ids(*meshes)[0]


def build_scene(mesh_path: Path):
    mesh, aabb = load_mesh(mesh_path)
    return make_scene(mesh), aabb


def has_lidar(frame, root: Path) -> bool:
    """Measured depth exists for this camera (the 360° rig faces have none)."""
    return (root / "confidence" / f"{Path(frame['file_path']).stem}.png").exists()


def lidar_depth_m(frame, root: Path):
    """Measured depth in metres at the depth raster's size, or None."""
    if Image is None or not has_lidar(frame, root):
        return None
    dpath = root / frame.get("depth_file_path", f"depth/{Path(frame['file_path']).stem}.png")
    if not dpath.exists():
        return None
    return np.asarray(Image.open(dpath)).astype(np.float32) / 1000.0


def lidar_points(frame, meta, root: Path, stride: int):
    """Confidence-2 LiDAR pixels unprojected to world points (N,3), or empty."""
    depth = lidar_depth_m(frame, root)
    if depth is None:
        return np.empty((0, 3), np.float32)
    stem = Path(frame["file_path"]).stem
    dh, dw = depth.shape
    conf_img = Image.open(root / "confidence" / f"{stem}.png").convert("L")
    if conf_img.size != (dw, dh):
        conf_img = conf_img.resize((dw, dh), Image.NEAREST)
    conf = np.asarray(conf_img)
    fx, fy, cx, cy, w, h = intrinsics(frame, meta)
    n = stride
    dd, cc = depth[n // 2::n, n // 2::n], conf[n // 2::n, n // 2::n]
    vv, uu = np.meshgrid(np.arange(n // 2, dh, n, dtype=np.float32),
                         np.arange(n // 2, dw, n, dtype=np.float32), indexing="ij")
    good = (cc >= 2) & (dd > 0.2) & (dd < 5.0)
    if not good.any():
        return np.empty((0, 3), np.float32)
    s = dw / w
    u, v, d = uu[good], vv[good], dd[good]
    xc = (u - cx * s) / (fx * s) * d
    yc = -(v - cy * s) / (fy * s) * d
    c2w = frame["transform_matrix"]
    R = np.array([row[:3] for row in c2w[:3]], dtype=np.float32)
    t = np.array([row[3] for row in c2w[:3]], dtype=np.float32)
    return np.stack([xc, yc, -d], -1).astype(np.float32) @ R.T + t


def make_bias_measure(frames, meta, root: Path):
    """Returns f(mesh) -> median(mesh_depth - lidar_depth) in metres over sample frames."""
    sample = [f for f in frames if has_lidar(f, root)][::BIAS_FRAME_STRIDE]
    cache = {}

    def measure(mesh):
        scene = make_scene(mesh)
        meds = []
        for f in sample:
            fx, fy, cx, cy, w, h = intrinsics(f, meta)
            _, dmm, hit = render_frame(scene, f["transform_matrix"], fx, fy, cx, cy, w, h, 4)
            key = f["file_path"]
            if key not in cache:
                cache[key] = lidar_depth_m(f, root)
            lid = cache[key]
            if lid is None or lid.shape != hit.shape:
                continue
            m = hit & (lid > 0.3) & (lid < 4.0)
            if m.sum() > 1000:
                meds.append(float(np.median(dmm[m] / 1000.0 - lid[m])))
        return float(np.median(meds)) if meds else 0.0

    return measure


def check_alignment(frames, aabb):
    """Camera track must intersect the mesh volume, else it's the wrong mesh/scan."""
    lo, hi = aabb
    centres = np.array([[f["transform_matrix"][r][3] for r in range(3)] for f in frames])
    pad = 1.0  # cameras may stand just outside the reconstructed surface
    inside = np.all((centres >= lo - pad) & (centres <= hi + pad), axis=1)
    frac = float(inside.mean())
    print(f"alignment: {frac * 100:.0f}% of {len(frames)} cameras inside mesh AABB (+{pad:.0f} m pad)")
    if frac < 0.5:
        sys.exit("mesh and camera track are disjoint — is this the OBJ export of the same scan?")


def render_frame(scene, c2w, fx, fy, cx, cy, w, h, downscale, depthless_ids=frozenset()):
    """Ray-cast one camera. Returns (normals float32 (h,w,3) world-space camera-facing,
    depth_mm uint16 (h,w), hit mask (h,w)).

    Hits on geometry whose id is in `depthless_ids` contribute a normal but depth 0
    (unknown): used for extrapolated geometry (the measured-ceiling extension) where the
    orientation is trustworthy but the exact height is not."""
    rw, rh = max(1, w // downscale), max(1, h // downscale)
    # Sample at the centre of each downscale block so nearest-upscale lands where it was cast.
    us = (np.arange(rw, dtype=np.float32) + 0.5) * (w / rw)
    vs = (np.arange(rh, dtype=np.float32) + 0.5) * (h / rh)
    uu, vv = np.meshgrid(us, vs)
    # ARKit/OpenGL camera: +X right, +Y up, -Z forward; image v grows downward.
    # z component fixed at -1 so t_hit IS the z-depth (same maths as validate.py).
    dirs_cam = np.stack([(uu - cx) / fx, -(vv - cy) / fy, -np.ones_like(uu)], axis=-1)
    R = np.array([row[:3] for row in c2w[:3]], dtype=np.float32)
    t = np.array([row[3] for row in c2w[:3]], dtype=np.float32)
    dirs = dirs_cam.reshape(-1, 3) @ R.T
    n_rays = dirs.shape[0]

    normals = np.empty((n_rays, 3), dtype=np.float32)
    depth = np.empty(n_rays, dtype=np.float32)
    gids = np.empty(n_rays, dtype=np.uint32) if depthless_ids else None
    for s in range(0, n_rays, RAY_CHUNK):
        e = min(s + RAY_CHUNK, n_rays)
        rays = np.concatenate([np.broadcast_to(t, (e - s, 3)), dirs[s:e]], axis=1)
        ans = scene.cast_rays(o3d.core.Tensor(rays.astype(np.float32)))
        depth[s:e] = ans["t_hit"].numpy()
        normals[s:e] = ans["primitive_normals"].numpy()
        if gids is not None:
            gids[s:e] = ans["geometry_ids"].numpy()

    hit = np.isfinite(depth) & (depth > 0)
    depthless = np.isin(gids, list(depthless_ids)) & hit if gids is not None else None
    # Face the camera: loss is (1 - cos), so a wrong sign actively fights training.
    flip = np.where(np.einsum("ij,ij->i", normals, dirs) > 0, -1.0, 1.0).astype(np.float32)
    normals *= flip[:, None]
    normals[~hit] = 0.0
    depth[~hit] = 0.0
    if depthless is not None:
        depth[depthless] = 0.0   # normal kept, depth unknown

    normals = normals.reshape(rh, rw, 3)
    depth_mm = np.clip(np.rint(depth * 1000.0), 0, 65535).astype(np.uint16).reshape(rh, rw)
    hit = hit.reshape(rh, rw)
    if downscale > 1:
        normals = np.repeat(np.repeat(normals, downscale, 0), downscale, 1)[:h, :w]
        depth_mm = np.repeat(np.repeat(depth_mm, downscale, 0), downscale, 1)[:h, :w]
        hit = np.repeat(np.repeat(hit, downscale, 0), downscale, 1)[:h, :w]
        # Non-divisible tails: repeat may come up short — pad with misses.
        if normals.shape[0] < h or normals.shape[1] < w:
            pn = np.zeros((h, w, 3), np.float32); pn[:normals.shape[0], :normals.shape[1]] = normals; normals = pn
            pd = np.zeros((h, w), np.uint16); pd[:depth_mm.shape[0], :depth_mm.shape[1]] = depth_mm; depth_mm = pd
            ph = np.zeros((h, w), bool); ph[:hit.shape[0], :hit.shape[1]] = hit; hit = ph
    return normals, depth_mm, hit


def encode_normals(normals):
    """(h,w,3) world-space -> RGB rows, v = n*0.5 + 0.5. Zero vectors land on 128 = inactive."""
    rgb = np.clip(np.rint((normals * 0.5 + 0.5) * 255.0), 0, 255).astype(np.uint8)
    return rgb


SEED_TOTAL_SAMPLES = 3_000_000
SEED_VOXEL_M = 0.03
SEED_MAX_POINTS = 400_000


def seed_samples(scene, frame, meta, root, budget):
    """Sample world points + colours for one frame from a small mesh-depth cast.

    Unlike the LiDAR seed this sees exactly what the mesh sees: full 360° rig views,
    no flying pixels, hole-filled surfaces. Colour comes straight from the RGB frame;
    masked (privacy-blurred) pixels are skipped.
    """
    fx, fy, cx, cy, w, h = intrinsics(frame, meta)
    n = max(1, int(math.sqrt(w * h / max(1, budget))))
    us = (np.arange(n // 2, w, n, dtype=np.float32)) + 0.5
    vs = (np.arange(n // 2, h, n, dtype=np.float32)) + 0.5
    uu, vv = np.meshgrid(us, vs)
    dirs_cam = np.stack([(uu - cx) / fx, -(vv - cy) / fy, -np.ones_like(uu)], -1).reshape(-1, 3)
    c2w = frame["transform_matrix"]
    R = np.array([row[:3] for row in c2w[:3]], dtype=np.float32)
    t = np.array([row[3] for row in c2w[:3]], dtype=np.float32)
    dirs = dirs_cam @ R.T
    rays = np.concatenate([np.broadcast_to(t, dirs.shape), dirs], axis=1).astype(np.float32)
    ans = scene.cast_rays(o3d.core.Tensor(rays))
    d = ans["t_hit"].numpy()
    keep = np.isfinite(d) & (d > 0.05)
    if not keep.any():
        return np.empty((0, 3), np.float32), np.empty((0, 3), np.uint8)
    pts = t + dirs[keep] * d[keep, None]

    px = np.clip(uu.reshape(-1)[keep].astype(np.int64), 0, w - 1)
    py = np.clip(vv.reshape(-1)[keep].astype(np.int64), 0, h - 1)
    cols = np.full((len(pts), 3), 128, np.uint8)
    if Image is not None:
        img = np.asarray(Image.open(root / frame["file_path"]).convert("RGB"))
        if img.shape[:2] == (h, w):
            cols = img[py, px]
        mp = frame.get("mask_path")
        if mp and (root / mp).exists():
            mask = np.asarray(Image.open(root / mp).convert("L"))
            if mask.shape == (h, w):
                m = mask[py, px] > 127
                pts, cols = pts[m], cols[m]
    return pts, cols


def seed_accumulate(acc, pts, cols):
    """Voxelise into `acc` (dict int64-key -> [sum_xyz, sum_rgb, count])."""
    if len(pts) == 0:
        return
    q = np.floor(pts / SEED_VOXEL_M).astype(np.int64)
    keys = (q[:, 0] + (1 << 20)) + ((q[:, 1] + (1 << 20)) << 21) + ((q[:, 2] + (1 << 20)) << 42)
    order = np.argsort(keys)
    keys, pts, cols = keys[order], pts[order], cols[order].astype(np.float64)
    uniq, start, cnt = np.unique(keys, return_index=True, return_counts=True)
    sums_p = np.add.reduceat(pts.astype(np.float64), start)
    sums_c = np.add.reduceat(cols, start)
    for k, sp, sc, c in zip(uniq.tolist(), sums_p, sums_c, cnt.tolist()):
        cell = acc.get(k)
        if cell is None:
            acc[k] = [sp, sc, c]
        else:
            cell[0] = cell[0] + sp
            cell[1] = cell[1] + sc
            cell[2] += c


RESCUE_DIST_M = 0.06     # LiDAR point counts as "missing from the mesh" beyond this
RESCUE_MIN_COUNT = 2     # voxel must be observed in 2+ frames — kills flying pixels
RESCUE_MAX_DEPTH_M = 5.0
RESCUE_STRIDE = 2        # dense: a 3 px cable must land on the grid, or there is nothing to rescue


def rescue_samples(scene, frame, meta, root, min_conf=2, min_dist=None):
    """LiDAR points the mesh does not explain — thin objects ARKit's ~5 cm fusion smoothed away.

    Unprojects measured depth (confidence 2 only) and keeps points farther than
    RESCUE_DIST_M from the mesh: by definition geometry the mesh missed. That set is thin
    structures plus flying pixels; the caller separates them with the multi-frame
    observation count (a chair leg repeats across frames, a flying pixel doesn't).
    """
    fx, fy, cx, cy, w, h = intrinsics(frame, meta)
    stem = Path(frame["file_path"]).stem
    conf_path = root / "confidence" / f"{stem}.png"
    dpath = root / frame.get("depth_file_path", f"depth/{stem}.png")
    if Image is None or not conf_path.exists() or not dpath.exists():
        return np.empty((0, 3), np.float32), np.empty((0, 3), np.uint8)

    depth = np.asarray(Image.open(dpath)).astype(np.float32) / 1000.0
    dh, dw = depth.shape
    conf_img = Image.open(conf_path).convert("L")
    if conf_img.size != (dw, dh):
        conf_img = conf_img.resize((dw, dh), Image.NEAREST)
    conf = np.asarray(conf_img)

    n = RESCUE_STRIDE
    dd = depth[n // 2::n, n // 2::n]
    cc = conf[n // 2::n, n // 2::n]
    vv, uu = np.meshgrid(np.arange(n // 2, dh, n, dtype=np.float32),
                         np.arange(n // 2, dw, n, dtype=np.float32), indexing="ij")
    good = (cc >= min_conf) & (dd > 0.2) & (dd < RESCUE_MAX_DEPTH_M)
    if not good.any():
        return np.empty((0, 3), np.float32), np.empty((0, 3), np.uint8)
    # Depth raster is a scaled view of the RGB camera — rescale intrinsics to it.
    s = dw / w
    u, v, d = uu[good], vv[good], dd[good]
    xc = (u - cx * s) / (fx * s) * d
    yc = -(v - cy * s) / (fy * s) * d
    c2w = frame["transform_matrix"]
    R = np.array([row[:3] for row in c2w[:3]], dtype=np.float32)
    t = np.array([row[3] for row in c2w[:3]], dtype=np.float32)
    pts = np.stack([xc, yc, -d], -1).astype(np.float32) @ R.T + t

    dist = scene.compute_distance(o3d.core.Tensor(pts)).numpy()
    off_mesh = dist > (RESCUE_DIST_M if min_dist is None else min_dist)
    if not off_mesh.any():
        return np.empty((0, 3), np.float32), np.empty((0, 3), np.uint8)
    pts = pts[off_mesh]

    cols = np.full((len(pts), 3), 128, np.uint8)
    img = np.asarray(Image.open(root / frame["file_path"]).convert("RGB"))
    if img.shape[:2] == (h, w):
        px = np.clip((u[off_mesh] / s).astype(np.int64), 0, w - 1)
        py = np.clip((v[off_mesh] / s).astype(np.int64), 0, h - 1)
        cols = img[py, px]
    return pts, cols


def seed_write(acc, rescue_acc, path: Path):
    cells = sorted(acc.values(), key=lambda c: -c[2])[:SEED_MAX_POINTS]
    # Rescue voxels: multi-frame observations only, and never where the mesh seed
    # already has that voxel (borderline points straddling the distance threshold).
    rescue = [c for k, c in rescue_acc.items()
              if c[2] >= RESCUE_MIN_COUNT and k not in acc] if rescue_acc else []
    rescue = sorted(rescue, key=lambda c: -c[2])[:max(0, SEED_MAX_POINTS - len(cells))]
    cells = cells + rescue
    header = (
        "ply\nformat binary_little_endian 1.0\n"
        f"element vertex {len(cells)}\n"
        "property float x\nproperty float y\nproperty float z\n"
        "property uchar red\nproperty uchar green\nproperty uchar blue\n"
        "end_header\n").encode("ascii")
    pts = np.array([c[0] / c[2] for c in cells], np.float32)
    cols = np.clip(np.array([c[1] / c[2] for c in cells]), 0, 255).astype(np.uint8)
    rec = np.zeros(len(cells), dtype=[("p", "<f4", 3), ("c", "u1", 3)])
    rec["p"], rec["c"] = pts, cols
    path.write_bytes(header + rec.tobytes())
    multi = sum(1 for c in cells if c[2] >= 2)
    print(f"seed cloud: {len(cells)} voxels ({SEED_VOXEL_M * 100:.0f} cm) -> {path}")
    print(f"            {len(cells) - len(rescue)} mesh-surface + {len(rescue)} LiDAR-rescue "
          f"(off-mesh > {RESCUE_DIST_M * 100:.0f} cm, seen {RESCUE_MIN_COUNT}+ frames)")
    print(f"            {multi} ({100 * multi // max(1, len(cells))}%) observed 2+ times")


# --- per-pixel prior gate -------------------------------------------------------------
# The mesh has no thin objects (~5 cm fusion), so at a chair-leg pixel the rendered normal
# says "wall/floor behind" and the rendered depth says the same. Measured on this room: a
# normal weight >= 0.05 erodes legs/stands completely, <= 0.02 keeps them — while the
# ceiling wants >= 0.2. No single weight resolves that, so the prior is silenced per pixel
# wherever MEASURED geometry sits in front of the mesh: the ceiling and walls keep the full
# prior, the leg gets none, and the photometric loss reconstructs it unopposed.
GATE_M = 0.08                 # PERPENDICULAR offset from the mesh surface — not range along the ray:
                              # at 15 deg grazing a 2 cm floor error is 8 cm of range, and the
                              # first version gated entire floors on exactly that
# Gating evidence is built SEPARATELY from the seed's rescue points, and much looser. A false
# gate costs a little prior in a small region; a missed one destroys the object. The seed's
# strict set (confidence 2, >= 2 frames, > 12 cm) had 33 projected points on the test scan's
# tripod — nothing to gate with, and its legs starved. Confidence >= 1 with the multi-frame
# voxel vote intact gives 68x that coverage; dropping to confidence 0 floods the room.
GATE_CONF = 1
GATE_MIN_COUNT = 2            # multi-frame vote is what kills single-frame LiDAR noise
GATE_EVIDENCE_M = 0.08        # off-mesh margin for gating evidence
GATE_HALO_M = 0.10            # physical halo around a thin object. The Gaussians that represent a
                              # 2 cm pole have 5-15 cm footprints and overlap the wall/floor pixels
                              # around it, where an active prior still reaches them from the side;
                              # a silhouette-width gate protected 31% of thin-object views and did
                              # nothing visible. The halo is sized per frame from range and focal.
GATE_HALO_MIN_PX = 6
GATE_LIDAR_DILATE_PX = 8      # raw-LiDAR gate: cover the ~7.5x upsampling edge, nothing more
GATE_HALO_MAX_PX = 120


def lidar_conf(frame, root: Path, shape):
    """Confidence raster resized (nearest) to `shape`, or None."""
    stem = Path(frame["file_path"]).stem
    p = root / "confidence" / f"{stem}.png"
    if Image is None or not p.exists():
        return None
    img = Image.open(p).convert("L")
    if img.size != (shape[1], shape[0]):
        img = img.resize((shape[1], shape[0]), Image.NEAREST)
    return np.asarray(img)


def ray_dirs_world(frame, meta, shape):
    """Unit ray direction per pixel, world frame, for a raster of `shape` covering the image."""
    fx, fy, cx, cy, w, h = intrinsics(frame, meta)
    rh, rw = shape
    us = (np.arange(rw, dtype=np.float32) + 0.5) * (w / rw)
    vs = (np.arange(rh, dtype=np.float32) + 0.5) * (h / rh)
    uu, vv = np.meshgrid(us, vs)
    d = np.stack([(uu - cx) / fx, -(vv - cy) / fy, -np.ones_like(uu)], -1)
    d /= np.linalg.norm(d, axis=-1, keepdims=True)
    R = np.array(frame["transform_matrix"], np.float32)[:3, :3]
    return d @ R.T


def _halo_px(fx, ranges):
    """Pixel radius of a GATE_HALO_M halo at the median of `ranges`."""
    if len(ranges) == 0:
        return GATE_HALO_MIN_PX
    return int(np.clip(fx * GATE_HALO_M / float(np.median(ranges)), GATE_HALO_MIN_PX, GATE_HALO_MAX_PX))


def _dilate(mask, px):
    from scipy import ndimage
    if px <= 0 or not mask.any():
        return mask
    # separable box dilation is far cheaper than a disk for px up to ~100
    return ndimage.binary_dilation(mask, structure=np.ones((3, 3), bool), iterations=px)


def evidence_mask(depth_mm, normals, frame, meta, evidence):
    """Pixels where projected off-mesh evidence (legs, rods, clutter the mesh lacks) sits in
    front of the mesh, perpendicular test, dilated by a physical halo. Returns (mask, n_hits)."""
    h, w = depth_mm.shape
    mask = np.zeros((h, w), bool)
    if evidence is None or len(evidence) == 0:
        return mask, 0
    fx, fy, cx, cy, _, _ = intrinsics(frame, meta)
    c2w = np.array(frame["transform_matrix"], np.float32)
    R, t = c2w[:3, :3], c2w[:3, 3]
    pc = (evidence - t) @ R
    rng = -pc[:, 2]
    ok = rng > 0.2
    u = np.floor(cx + fx * pc[ok, 0] / rng[ok]).astype(np.int64)
    v = np.floor(cy - fy * pc[ok, 1] / rng[ok]).astype(np.int64)
    r = rng[ok]
    inside = (u >= 0) & (u < w) & (v >= 0) & (v < h)
    u, v, r = u[inside], v[inside], r[inside]
    if len(u) == 0:
        return mask, 0
    mesh_m = depth_mm[v, u].astype(np.float32) / 1000.0
    dirs = pc[ok][inside] / np.linalg.norm(pc[ok][inside], axis=1, keepdims=True) @ R.T
    cosang = np.abs(np.einsum("ij,ij->i", normals[v, u], dirs))
    # in front of the mesh, or where the mesh has nothing at all (unknown depth): both mean
    # the prior here is not describing this object
    front = (mesh_m <= 0) | ((mesh_m - r) * cosang > GATE_M)
    if not front.any():
        return mask, 0
    mask[v[front], u[front]] = True
    return _dilate(mask, _halo_px(fx, r[front])), int(front.sum())


def gate_arkit(normals, depth_mm, frame, meta, root: Path, evidence):
    """ARKit frame: blank the normal prior where measured geometry sits in front of the mesh —
    LiDAR pixels (any confidence: thin objects come back at confidence 0) and projected
    evidence, both with the physical halo. Depth is not touched (measured LiDAR)."""
    lid = lidar_depth_m(frame, root)
    mask = np.zeros(depth_mm.shape, bool)
    if lid is not None and lid.shape == depth_mm.shape:
        # Raw LiDAR disagreement, confidence >= 1, small fixed dilation only. Without the
        # confidence filter and with the physical halo this fired on 68% of ARKit pixels —
        # low-confidence returns are noise, and a halo turns noise into whole frames. Thin
        # objects at confidence 0 are covered by the evidence projection below instead.
        conf = lidar_conf(frame, root, lid.shape)
        mesh_m = depth_mm.astype(np.float32) / 1000.0
        cosang = np.abs(np.einsum("ijk,ijk->ij", normals, ray_dirs_world(frame, meta, lid.shape)))
        front = (lid > 0.2) & (mesh_m > 0) & ((mesh_m - lid) * cosang > GATE_M)
        if conf is not None:
            front &= conf >= 1
        if front.any():
            mask |= _dilate(front, GATE_LIDAR_DILATE_PX)
    ev, _ = evidence_mask(depth_mm, normals, frame, meta, evidence)
    mask |= ev
    normals[mask] = 0.0
    return float(mask.mean())


def gate_rig(normals, depth_mm, frame, meta, evidence):
    """Rig face (no LiDAR): projected evidence with halo; blank normal AND depth — both
    priors are wrong where the mesh lacks the object."""
    mask, _ = evidence_mask(depth_mm, normals, frame, meta, evidence)
    normals[mask] = 0.0
    depth_mm[mask] = 0
    return float(mask.mean())


def depth_is_filler(path: Path) -> bool:
    """True when the existing depth map is the all-zero filler (or absent)."""
    if not path.exists():
        return True
    if Image is None:
        # Cheap proxy: an all-zero 16-bit PNG deflates to a few KB even at 4032x3024.
        return path.stat().st_size < 16384
    return int(np.max(np.asarray(Image.open(path)))) == 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("root", type=Path, help="converted dataset dir (contains transforms.json)")
    ap.add_argument("--mesh", type=Path, default=None,
                    help="ARKit mesh OBJ in the scan's world frame "
                         "(default: <root>/mesh.obj, then <root>/../mesh.obj)")
    ap.add_argument("--render-depth", choices=["missing", "nolidar", "all", "none"], default="missing",
                    help="missing: replace only all-zero filler depth maps (rig faces); "
                         "nolidar: every camera without a confidence map (idempotent form of "
                         "'missing'); all: overwrite every depth map with mesh depth; none: normals only")
    ap.add_argument("--debias", default="auto", metavar="auto|off|CM",
                    help="displace the mesh along its normals to remove the fusion iso-surface "
                         "bias, measured against this scan's LiDAR (auto, default), or by a fixed "
                         "number of cm, or off")
    ap.add_argument("--roomplan", type=Path, default=None,
                    help="roomplan.json: fill mesh holes in RoomPlan planes (walls, floor, table/"
                         "storage box faces) where LiDAR evidence encloses them; writes "
                         "<root>/mesh_filled.obj")
    ap.add_argument("--registration", default="auto", metavar="auto|off|PATH",
                    help="registration.json of the bundle: mesh.obj and roomplan.json are stored in "
                         "the location's canonical frame while the cameras stay in the raw capture "
                         "frame; its inverse is applied to mesh + RoomPlan so everything shares the "
                         "camera frame (auto: look beside the dataset; measured ~5 cm on the test scan)")
    ap.add_argument("--ceiling", choices=["off", "measured", "measured-depth"], default="off",
                    help="measured: extend the ceiling the mesh itself measured (ceiling-labelled "
                         "faces when face_classes.bin is present, dominant height peak) locally "
                         "across the RoomPlan footprint as NORMALS-ONLY geometry; measured-depth: "
                         "the extension carries depth too (boxy rooms). Needs --roomplan. Refuses "
                         "when not a room, too little measured, or multimodal heights")
    ap.add_argument("--floor", choices=["off", "full"], default="off",
                    help="full: one quad over the RoomPlan floor footprint at the height of the "
                         "floor-labelled mesh faces, with depth + normals — fills every floor gap "
                         "the LiDAR-less rig views have. Refuses on multimodal (split-level) heights")
    ap.add_argument("--gate", choices=["on", "off"], default="on",
                    help="per-pixel prior gate (default on): blank the mesh normal prior where "
                         "LiDAR sees a surface >= 8 cm in front of the mesh (ARKit frames), and "
                         "blank normal + depth where projected off-mesh LiDAR evidence sits in "
                         "front of the mesh (rig faces). Keeps thin objects under a strong normal "
                         "weight; ceiling and walls keep the full prior")
    ap.add_argument("--face-classes", default="auto", metavar="auto|off|PATH",
                    help="face_classes.bin (ARKit per-face labels aligned to mesh.obj) used to "
                         "measure floor/ceiling heights (auto: beside the mesh or the dataset)")
    ap.add_argument("--downscale", type=int, default=1,
                    help="cast rays every NxN pixels and nearest-upscale (prototype speed knob; "
                         "normals are piecewise constant per face so N=2..4 is usually invisible)")
    ap.add_argument("--only", default=None, help="substring filter on file_path")
    ap.add_argument("--seed", default=None, metavar="NAME",
                    help="also build a mesh-based seed cloud (e.g. 'sparse_pc.ply' to replace "
                         "the LiDAR one) — sampled from mesh depth in every view incl. the 360° "
                         "rig, coloured from the RGB frames, mask-filtered")
    ap.add_argument("--normals", choices=["write", "skip"], default="write",
                    help="write: mesh-rendered normal maps into normals/ (original behaviour). "
                         "skip: seed/depth only; generate normals with MoGe instead "
                         "(LichtFeld-Studio preprocess <bundle> --mode normals). Only frames that "
                         "need a rendered depth map are ray-cast; the prior gate is disabled")
    ap.add_argument("--no-rescue", action="store_true",
                    help="with --seed: skip the LiDAR rescue pass (thin objects missing from "
                         "the mesh, recovered from measured depth far off the mesh surface)")
    args = ap.parse_args()

    root = args.root.resolve()
    mesh_path = args.mesh
    if mesh_path is None:
        for cand in (root / "mesh.obj", root.parent / "mesh.obj"):
            if cand.exists():
                mesh_path = cand
                break
        if mesh_path is None:
            sys.exit("no mesh.obj beside the dataset — export the scan as OBJ and pass --mesh")

    meta, frames = load_frames(root)
    all_frames = frames
    if args.only:
        frames = [f for f in frames if args.only in f.get("file_path", "")]
        print(f"--only {args.only!r}: {len(frames)} frames")
    mesh, aabb = load_mesh(mesh_path)

    labels = None
    if args.face_classes != "off":
        cands = ([Path(args.face_classes)] if args.face_classes != "auto"
                 else [mesh_path.with_name("face_classes.bin"), root / "face_classes.bin"])
        fc = next((c for c in cands if c.exists()), None)
        if fc is not None:
            labels = load_face_classes(fc, len(mesh.triangles))
            if labels is not None:
                counts = np.bincount(labels, minlength=8)
                print(f"face classes: {fc.name} — floor {counts[2]:,} ceiling {counts[3]:,} "
                      f"window {counts[6]:,} door {counts[7]:,} faces")

    # Frame: registration.json documents that mesh.obj/roomplan.json were re-expressed in the
    # location's canonical frame while cameras/*.json stayed raw. Undo it here so mesh, RoomPlan
    # and cameras agree (measured: a 4.9 cm shift whose per-view signature correlated -0.60
    # with the depth residuals; undoing it removed the correlation).
    reg_M = None
    if args.registration != "off":
        cands = ([Path(args.registration)] if args.registration != "auto"
                 else [root / "registration.json", root.parent / "registration.json"])
        reg_path = next((c for c in cands if c.exists()), None)
        if reg_path is not None:
            reg = json.loads(reg_path.read_text())
            if reg.get("applied") and "transform" in reg:
                T = np.array(reg["transform"], dtype=np.float64).reshape(4, 4).T
                reg_M = np.linalg.inv(T)
                mesh.transform(reg_M)
                v = np.asarray(mesh.vertices)
                aabb = (v.min(axis=0), v.max(axis=0))
                print(f"registration: undone from {reg_path.name} (|t| = {100 * np.linalg.norm(T[:3, 3]):.1f} cm, "
                      f"yaw {reg.get('yawDeg', 0):.2f}°) — mesh now in the camera frame")
            else:
                print(f"registration: {reg_path.name} present but not applied — mesh left as is")
    check_alignment(frames, aabb)

    # --- mesh repair: debias, then fill planar holes ---------------------------------
    repaired = False
    if args.debias != "off":
        measure = make_bias_measure(all_frames, meta, root)
        if args.debias == "auto":
            mesh, moved, hist = debias(mesh, measure)
            print(f"debias: mesh - LiDAR " + " -> ".join(f"{100 * b:+.1f}" for b in hist)
                  + f" cm; displaced {100 * moved:+.1f} cm along normals")
        else:
            step = float(args.debias) / 100.0
            mesh.compute_vertex_normals()
            mesh.vertices = o3d.utility.Vector3dVector(
                np.asarray(mesh.vertices) + step * np.asarray(mesh.vertex_normals))
            print(f"debias: displaced {100 * step:+.1f} cm along normals (fixed); "
                  f"residual {100 * measure(mesh):+.1f} cm")
        repaired = True
    scene = make_scene(mesh)

    patch = None
    if args.roomplan:
        planes = load_roomplan(args.roomplan)
        if reg_M is not None:
            planes = transform_planes(planes, reg_M)
        lidar_frames = [f for f in all_frames if has_lidar(f, root)]
        print(f"hole fill: {len(planes)} RoomPlan planes, LiDAR evidence from {len(lidar_frames)} frames ...")
        for f in lidar_frames:
            accumulate_evidence(planes, lidar_points(f, meta, root, EVIDENCE_STRIDE))
        patch, report = build_patches(planes, scene)
        print("\n".join(report))
        n_tris = len(patch.triangles)
        if n_tris:
            area = n_tris / 2 * 0.03 * 0.03
            print(f"hole fill: {n_tris:,} patch triangles ({area:.2f} m²) added to the mesh")
            scene = make_scene(mesh, patch)
            repaired = True
        else:
            print("hole fill: nothing to patch")
    # Asserted geometry (carries depth + normals): mesh, evidence-gated patches, and — when
    # asked — the full floor quad and a depth-carrying ceiling. Depthless geometry (normals
    # only): the normals-only ceiling extension. Seeds and rescue see the asserted set.
    asserted = [mesh, patch]
    depthless_geoms = []
    if args.floor != "off" or args.ceiling != "off":
        if not args.roomplan:
            sys.exit("--floor / --ceiling need --roomplan (footprint + room check)")
    if args.floor == "full":
        floor_quad, rep = build_floor(mesh, planes, labels)
        print("\n".join(rep))
        if len(floor_quad.triangles):
            asserted.append(floor_quad)
            repaired = True
    if args.ceiling != "off":
        ceil_patch, rep, ceil_h = build_ceiling(mesh, planes, labels)
        print("\n".join(rep))
        if len(ceil_patch.triangles):
            if args.ceiling == "measured-depth":
                asserted.append(ceil_patch)
                repaired = True
                print("ceiling extension carries depth (measured-depth)")
            else:
                depthless_geoms.append(ceil_patch)
                o3d.io.write_triangle_mesh(str(root / "ceiling_ext.obj"), ceil_patch, write_vertex_normals=False)
                print(f"ceiling extension -> {root / 'ceiling_ext.obj'} (normals-only; not in mesh_filled.obj)")

    scene = make_scene(*asserted)
    scene_render, ids = make_scene_ids(*asserted, *depthless_geoms)
    depthless = frozenset(i for i in ids[len(asserted):] if i is not None)

    if repaired:
        out_mesh = o3d.geometry.TriangleMesh(mesh)
        for g in asserted[1:]:
            if g is not None and len(g.triangles):
                out_mesh += g
        o3d.io.write_triangle_mesh(str(root / "mesh_filled.obj"), out_mesh, write_vertex_normals=False)
        print(f"repaired mesh -> {root / 'mesh_filled.obj'} ({len(out_mesh.triangles):,} tris; "
              f"everything that carries depth)")

    # Off-mesh LiDAR evidence (the rescue voxels) is needed up front: the rig-face gate
    # projects it, and the rig faces render after the ARKit frames. One pass over the
    # LiDAR frames; the hybrid seed reuses the same accumulator.
    write_normals = args.normals == "write"
    if not write_normals and args.gate == "on":
        print("prior gate: off (--normals skip; the gate only edits mesh-rendered normals)")
    gate_on = args.gate == "on" and write_normals
    rescue_acc = {} if (args.seed and not args.no_rescue) else None
    evidence = None
    lidar_frames = [f for f in all_frames if has_lidar(f, root)]
    if rescue_acc is not None:
        t_ev = time.time()
        for f in lidar_frames:
            pts, cols = rescue_samples(scene, f, meta, root)
            seed_accumulate(rescue_acc, pts, cols)
        n_seed = sum(1 for c in rescue_acc.values() if c[2] >= RESCUE_MIN_COUNT)
        print(f"seed rescue: {n_seed:,} voxels (confidence 2, > {RESCUE_DIST_M * 100:.0f} cm off mesh, "
              f"seen {RESCUE_MIN_COUNT}+ frames) from {len(lidar_frames)} frames, {time.time() - t_ev:.0f}s")
    if gate_on:
        t_ev = time.time()
        gate_acc = {}
        for f in lidar_frames:
            pts, cols = rescue_samples(scene, f, meta, root, min_conf=GATE_CONF, min_dist=GATE_EVIDENCE_M)
            seed_accumulate(gate_acc, pts, cols)
        cells = [c for c in gate_acc.values() if c[2] >= GATE_MIN_COUNT]
        evidence = (np.ascontiguousarray(np.array([c[0] / c[2] for c in cells], np.float32))
                    if cells else np.empty((0, 3), np.float32))
        print(f"gate evidence: {len(evidence):,} voxels (confidence {GATE_CONF}+, > {GATE_EVIDENCE_M * 100:.0f} cm "
              f"off mesh, seen {GATE_MIN_COUNT}+ frames), {time.time() - t_ev:.0f}s")

    out_dir = root / "normals"
    if write_normals:
        out_dir.mkdir(exist_ok=True)
    depth_written = 0
    coverage = []
    gated_arkit, gated_rig = [], []
    seed_acc = {} if args.seed else None
    seed_budget = SEED_TOTAL_SAMPLES // max(1, len(frames))
    t0 = time.time()

    for i, f in enumerate(frames):
        fx, fy, cx, cy, w, h = intrinsics(f, meta)
        stem = Path(f["file_path"]).stem
        dpath = root / f.get("depth_file_path", f"depth/{stem}.png")
        want_depth = args.render_depth != "none" and (
            args.render_depth == "all"
            or (args.render_depth == "missing" and depth_is_filler(dpath))
            or (args.render_depth == "nolidar" and not has_lidar(f, root)))
        # With --normals skip, only frames that need a rendered depth map are ray-cast.
        if write_normals or want_depth:
            normals, depth_mm, hit = render_frame(
                scene_render, f["transform_matrix"], fx, fy, cx, cy, w, h, max(1, args.downscale),
                depthless_ids=depthless)
            coverage.append(float(hit.mean()))

        if seed_acc is not None:
            pts, cols = seed_samples(scene, f, meta, root, seed_budget)
            seed_accumulate(seed_acc, pts, cols)

        if gate_on:
            if has_lidar(f, root):
                gated_arkit.append(gate_arkit(normals, depth_mm, f, meta, root, evidence))
            else:
                gated_rig.append(gate_rig(normals, depth_mm, f, meta, evidence))

        if write_normals:
            rgb = encode_normals(normals)
            write_png8_rgb(out_dir / f"{stem}.png", w, h, [rgb[r].tobytes() for r in range(h)])

        if want_depth:
            dpath.parent.mkdir(exist_ok=True)
            be = depth_mm.astype(">u2")
            write_png16_gray(dpath, w, h, [be[r].tobytes() for r in range(h)])
            depth_written += 1

        if (i + 1) % 10 == 0 or i + 1 == len(frames):
            el = time.time() - t0
            cov_msg = f", coverage {100 * coverage[-1]:.0f}%" if coverage else ""
            print(f"  [{i + 1}/{len(frames)}] {el:.0f}s{cov_msg}")

    cov = sorted(coverage)
    if write_normals:
        print(f"\nnormals: {len(frames)} maps -> {out_dir}")
    else:
        print(f"\nnormals: skipped ({len(cov)} frames ray-cast for depth)")
    if cov:
        print(f"coverage: median {100 * cov[len(cov) // 2]:.0f}%, min {100 * cov[0]:.0f}%")
    print(f"depth maps written: {depth_written} ({args.render_depth})")
    if gate_on:
        ga = 100 * float(np.mean(gated_arkit)) if gated_arkit else 0.0
        gr = 100 * float(np.mean(gated_rig)) if gated_rig else 0.0
        print(f"prior gate: normals blanked on {ga:.2f}% of ARKit-frame pixels (LiDAR >= {GATE_M * 100:.0f} cm "
              f"in front of mesh); normals+depth blanked on {gr:.2f}% of rig-face pixels (projected evidence)")
    if seed_acc is not None:
        seed_write(seed_acc, rescue_acc if not args.no_rescue else None, root / args.seed)
        # The app's export ships no seed (policy stays training-side), so make sure the
        # engines can find this one.
        if meta.get("ply_file_path") != args.seed:
            meta["ply_file_path"] = args.seed
            (root / "transforms.json").write_text(json.dumps(meta, indent=2))
            print(f"transforms.json: ply_file_path -> {args.seed}")
    if cov and cov[len(cov) // 2] < 0.3:
        print("WARNING: low mesh coverage — supervision will be sparse; "
              "check the mesh is complete for this scan")
    if write_normals:
        print("\ntrain with: --use-normal-loss --normal-loss-space world "
              "(plus your existing --use-depth-loss)")
    else:
        print("\nnext: LichtFeld-Studio preprocess <bundle> --mode normals (MoGe normals), "
              "then train with --use-depth-loss --use-normal-loss")


if __name__ == "__main__":
    main()
