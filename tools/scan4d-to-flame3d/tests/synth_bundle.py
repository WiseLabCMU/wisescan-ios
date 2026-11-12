"""Synthetic Scan4D Nerfstudio export with exactly known geometry.

A box room with a table in it, captured by a ring of cameras. Depth and colour are ray-cast
analytically, so every pixel's true depth is known in closed form. The layout follows
NerfstudioExport:

- cameras in the scan's RAW frame; mesh.obj in the CANONICAL frame, related by an applied
  registration.json (column-major raw->canonical)
- stream frames plus hi-res stills in one ``frame_NNNNN`` sequence, per-frame intrinsics
- one still at a different aspect ratio, and two 360° cube faces (``face`` key, own stems)
- depth/ upsampled nearest-neighbour from a LiDAR raster to each image's size, with
  confidence/ left at the LiDAR raster

All sizes are small so the tests run in seconds.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np
from PIL import Image

ROOM = (np.array([-2.0, 0.0, -1.5]), np.array([2.0, 2.5, 1.5]))
TABLE = (np.array([0.2, 0.0, -0.6]), np.array([0.8, 0.7, 0.0]))

STREAM = (192, 144, 150.0)       # w, h, focal; the LiDAR raster is a third of it
STILL = (384, 288, 300.0)
WIDE_STILL = (384, 216, 300.0)   # 16:9, must be dropped
FACE = 128
LIDAR_DIV = 3

# Raw -> canonical: yaw 12° about +Y, then a 35 cm / -20 cm shift.
YAW = math.radians(12.0)
REGISTRATION = np.array([
    [math.cos(YAW), 0, math.sin(YAW), 0.35],
    [0, 1, 0, 0.02],
    [-math.sin(YAW), 0, math.cos(YAW), -0.20],
    [0, 0, 0, 1],
])


def c2w_gl(position, yaw_deg: float, pitch_deg: float) -> np.ndarray:
    """ARKit camera-to-world: OpenGL camera axes (+X right, +Y up, looks down -Z)."""
    a, p = math.radians(yaw_deg), math.radians(pitch_deg)
    ry = np.array([[math.cos(a), 0, math.sin(a)], [0, 1, 0], [-math.sin(a), 0, math.cos(a)]])
    rx = np.array([[1, 0, 0], [0, math.cos(p), -math.sin(p)], [0, math.sin(p), math.cos(p)]])
    m = np.eye(4)
    m[:3, :3] = ry @ rx
    m[:3, 3] = position
    return m


def raycast(c2w: np.ndarray, fx, fy, cx, cy, w, h):
    """Z-depth (m) and RGB at pixel centres, in the raw frame."""
    u, v = np.meshgrid(np.arange(w) + 0.5, np.arange(h) + 0.5)
    d_cam = np.stack([(u - cx) / fx, -(v - cy) / fy, -np.ones_like(u)], axis=-1)
    d = d_cam @ c2w[:3, :3].T            # forward component of d_cam is 1, so t == z-depth
    o = c2w[:3, 3]
    with np.errstate(divide="ignore", invalid="ignore"):
        lo, hi = ROOM
        exits = np.where(d > 0, (hi - o) / d, np.where(d < 0, (lo - o) / d, np.inf))
        t_room = exits.min(axis=-1)
        t1, t2 = (TABLE[0] - o) / d, (TABLE[1] - o) / d
        t_in = np.nanmax(np.minimum(t1, t2), axis=-1)
        t_out = np.nanmin(np.maximum(t1, t2), axis=-1)
    hits_table = (t_out >= t_in) & (t_in > 0) & (t_in < t_room)
    t = np.where(hits_table, t_in, t_room)
    rgb = surface_rgb(o + d * t[..., None], hits_table)
    return t.astype(np.float64), np.clip(rgb, 0, 255).astype(np.uint8)


def surface_rgb(p: np.ndarray, on_table: np.ndarray) -> np.ndarray:
    """True sRGB colour (0-255 float) of raw-frame surface points: a 25 cm checker over a
    blue room and a red table, brightening with height. The checker is offset half a cell
    so no wall or table face lies on a cell edge, where float noise would pick the side."""
    checker = (np.floor((p + 0.125) / 0.25).sum(axis=-1) % 2)[..., None]
    base = np.where(on_table[..., None], [200, 60, 40], [70, 120, 190])
    shade = 0.55 + 0.45 * checker
    tone = 0.8 + 0.2 * (np.abs(p[..., 1:2]) / 2.5)
    return base * shade * tone


def _grid_box(lo, hi, step):
    """Surface vertices + triangles of an axis-aligned box, gridded at about ``step``."""
    verts, tris = [], []
    for axis in range(3):
        a1, a2 = [k for k in range(3) if k != axis]
        n1 = max(1, round((hi[a1] - lo[a1]) / step))
        n2 = max(1, round((hi[a2] - lo[a2]) / step))
        for side in (lo[axis], hi[axis]):
            base = len(verts)
            for i in range(n1 + 1):
                for j in range(n2 + 1):
                    p = np.empty(3)
                    p[axis] = side
                    p[a1] = lo[a1] + (hi[a1] - lo[a1]) * i / n1
                    p[a2] = lo[a2] + (hi[a2] - lo[a2]) * j / n2
                    verts.append(p)
            for i in range(n1):
                for j in range(n2):
                    q = base + i * (n2 + 1) + j
                    tris += [(q, q + n2 + 1, q + n2 + 2), (q, q + n2 + 2, q + 1)]
    return np.array(verts), np.array(tris)


def room_mesh_raw():
    rv, rt = _grid_box(*ROOM, 0.1)
    tv, tt = _grid_box(*TABLE, 0.05)
    return np.vstack([rv, tv]), np.vstack([rt, tt + len(rv)])


def mesh_truth_rgb() -> tuple[np.ndarray, np.ndarray]:
    """True sRGB colour (0-1) of every mesh vertex, and a mask of the vertices whose colour
    is unambiguous: off the 25 cm checker edges, off the table's edges (a silhouette vertex
    lands on the boundary between table and wall pixels), and not on the table face
    resting on the floor, which no camera sees."""
    verts, _ = room_mesh_raw()
    n_room = len(_grid_box(*ROOM, 0.1)[0])
    on_table = np.arange(len(verts)) >= n_room
    rgb = surface_rgb(verts, on_table) / 255.0
    cells = (verts + 0.125) / 0.25
    off_edge = (np.abs(cells - np.round(cells)) > 0.1).all(axis=1)    # >= 2.5 cm from an edge
    on_bounds = np.sum([np.isclose(verts[:, k], TABLE[0][k]) | np.isclose(verts[:, k], TABLE[1][k])
                        for k in range(3)], axis=0)
    silhouette = on_table & (on_bounds >= 2)
    hidden = on_table & (verts[:, 1] < 1e-6)
    return rgb, off_edge & ~silhouette & ~hidden


def _save_png16(arr_m: np.ndarray, path: Path):
    Image.fromarray(np.clip(arr_m * 1000.0, 0, 65535).astype(np.uint16)).save(path)


def _upsample_nearest(arr, w, h):
    sh, sw = arr.shape
    return arr[(np.arange(h) * sh // h)[:, None], (np.arange(w) * sw // w)[None, :]]


def camera_track(n_stream: int = 16):
    """[(stem, c2w, (w, h, f), kind)] in sequence order: stills at indices 5 and 11, the
    wide still at 14, and two cube faces after the stream."""
    track = []
    for i in range(n_stream + 3):
        ang = 360.0 * i / (n_stream + 3)
        pos = np.array([1.0 * math.cos(math.radians(ang)), 1.4 + 0.05 * math.sin(i),
                        1.0 * math.sin(math.radians(ang))])
        yaw = ang + (180.0 if i % 2 else 20.0)      # alternate: look outward / inward
        kind, spec = "stream", STREAM
        if i in (5, 11):
            kind, spec = "still", STILL
        elif i == 14:
            kind, spec = "still", WIDE_STILL
        track.append((f"frame_{i:05d}", c2w_gl(pos, yaw, -15.0), spec, kind))
    for face, yaw in (("front", 0.0), ("right", -90.0)):
        track.append((f"still_0001_{face}", c2w_gl(np.array([-0.5, 1.5, 0.4]), yaw, 0.0),
                      (FACE, FACE, FACE / 2), "face"))
    return track


def make_bundle(root: Path, *, registration: bool = True, n_stream: int = 16) -> Path:
    """Write the bundle into ``root`` and return it."""
    for sub in ("images", "depth", "confidence", "cameras"):
        (root / sub).mkdir(parents=True, exist_ok=True)

    verts, tris = room_mesh_raw()
    canon = verts @ REGISTRATION[:3, :3].T + REGISTRATION[:3, 3]
    with open(root / "mesh.obj", "w") as fh:
        fh.writelines(f"v {x:.6f} {y:.6f} {z:.6f}\n" for x, y, z in canon)
        fh.writelines(f"f {a + 1} {b + 1} {c + 1}\n" for a, b, c in tris)

    frames = []
    for idx, (stem, c2w, (w, h, f), kind) in enumerate(camera_track(n_stream)):
        # ARKit refines focal length continuously: give every frame its own intrinsics.
        fx = f * (1 + 0.001 * idx)
        cx, cy = w / 2 + 0.3, h / 2 - 0.2
        _, rgb = raycast(c2w, fx, fx, cx, cy, w, h)
        Image.fromarray(rgb).save(root / "images" / f"{stem}.jpg", quality=95)
        entry = {"file_path": f"images/{stem}.jpg", "transform_matrix": c2w.tolist(),
                 "fl_x": fx, "fl_y": fx, "cx": cx, "cy": cy, "w": w, "h": h,
                 "depth_file_path": f"depth/{stem}.png"}
        if kind == "face":
            entry.update(face=stem.rsplit("_", 1)[1], is_keyframe=True)
            depth_m, _ = raycast(c2w, fx, fx, cx, cy, w, h)     # mesh-rendered, no LiDAR
        else:
            # One sensor raster for every frame, as on device (256x192 there).
            lw = STREAM[0] // LIDAR_DIV
            lh = round(lw * h / w)
            s = lw / w
            lidar, _ = raycast(c2w, fx * s, fx * s, cx * s, cy * s, lw, lh)
            Image.fromarray(np.full((lh, lw), 2, np.uint8)).save(root / "confidence" / f"{stem}.png")
            entry["confidence_file_path"] = f"confidence/{stem}.png"
            depth_m = _upsample_nearest(lidar, w, h)
            if kind == "still":
                entry["is_keyframe"] = True
        _save_png16(depth_m, root / "depth" / f"{stem}.png")
        frames.append(entry)

    (root / "transforms.json").write_text(json.dumps({
        "camera_model": "OPENCV", "k1": 0.0, "k2": 0.0, "p1": 0.0, "p2": 0.0,
        "depth_unit_scale_factor": 0.001, "frames": frames}, indent=2))
    (root / "roomplan.json").write_text(json.dumps(
        {"version": 1, "source": "roomplan", "surfaces": [], "objects": []}))
    if registration:
        (root / "registration.json").write_text(json.dumps({
            "version": 2, "applied": True, "reason": "applied",
            "transform": REGISTRATION.T.reshape(-1).tolist(),     # column-major
            "transM": float(np.linalg.norm(REGISTRATION[:3, 3])), "yawDeg": 12.0,
            "initialRMSmm": 0, "finalRMSmm": 0, "matchedWalls": 4, "matchedFloors": 1,
            "weakAxisFrac": 0, "converged": True, "targetScanId": "SYNTH",
            "note": "synthetic"}))
    return root


def truth_depth(stem: str, w: int, h: int, n_stream: int = 16) -> np.ndarray:
    """Exact z-depth for one output frame at (w, h), from the converter's scaled intrinsics."""
    for idx, (s, c2w, (sw, sh, f), _) in enumerate(camera_track(n_stream)):
        if s == stem:
            fx = f * (1 + 0.001 * idx)
            sx, sy = w / sw, h / sh
            depth, _ = raycast(c2w, fx * sx, fx * sy, (sw / 2 + 0.3) * sx, (sh / 2 - 0.2) * sy,
                               w, h)
            return depth
    raise KeyError(stem)
