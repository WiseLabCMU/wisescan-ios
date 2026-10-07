#!/usr/bin/env python3
"""Convert a Scan4D Nerfstudio export into a flame3d-core ``polycam`` input bundle.

flame3d-core segments a capture into captioned, queryable 3D objects. Its ``polycam`` data
source reads a Polycam raw-data export; this script writes that layout from the Scan4D
**Nerfstudio** export, so a Scan4D capture runs through flame3d with no flame3d change:

    input.zip
    ├── keyframes/
    │   ├── images/<stem>.jpg              RGB, ONE resolution for every frame
    │   ├── corrected_cameras/<stem>.json  t_00..t_23 = camera-to-world, row-major, ARKit raw
    │   │                                  frame, OpenGL camera axes; fx fy cx cy width height
    │   └── depth/<stem>.png               16-bit mm LiDAR depth at the LiDAR's own raster
    ├── raw.glb                            mesh.obj as binary glTF (canonical frame, Y-up),
    │                                      vertex colours (COLOR_0) sampled from the frames
    ├── mesh_info.json                     alignmentTransform = registration.json's transform
    └── scan4d/                            conversion.json provenance + roomplan/registration

FRAMES OF REFERENCE, and why nothing is re-expressed here. The bundle's cameras stay in
the scan's raw capture frame while mesh.obj is in the location's canonical frame;
registration.json holds the raw->canonical transform, column-major. flame3d's Polycam
loader computes ``c2w = alignmentTransform @ c2w`` with alignmentTransform read
column-major from mesh_info.json: the same relationship in the same encoding, so the
transform passes through verbatim and the cameras stay raw. flame3d then rotates
everything Y-up -> Z-up and flips the camera axes OpenGL -> OpenCV itself.

WHAT flame3d ASSUMES ABOUT FRAMES (flame3d-core @ c8e1595):
- They are a video. normalize_labels orders frames by the trailing integer of the stem
  (``re.search(r"(\\d+)$")``, a ValueError without one) and builds runs of consecutive
  positions; SAM3's video predictor then tracks objects through each run. The stream
  frames and hi-res stills share one temporal ``frame_NNNNN`` sequence, so both are kept.
  The 360° cube faces are never written: their stems end in a face name, they sort after
  the whole stream, and they jump 90° face to face, so no ordering of them tracks.
- One resolution. A SAM3 run is one video; a mask whose size differs from its image is
  skipped by associate2d3d and raises IndexError in mask_graph. The hi-res stills are
  therefore resized to exactly the stream frames' size (their intrinsics scaled to
  match), and a still whose aspect ratio differs is dropped rather than letterboxed.
- Every frame is loaded into RAM, and one VLM call is made per frame. ``--stride``
  thins the stream when a capture is long.

DEPTH. flame3d renders depth from the mesh and only requires each frame to have a
readable depth PNG; it still holds every map in RAM as float32. So depth is written at the
LiDAR's own raster (the size of the frame's confidence map, 256x192 on current devices),
which is also what a real Polycam export ships. The Nerfstudio bundle had upsampled it
nearest-neighbour to the image size; sampling it back down nearest-neighbour recovers
the measured values. ``--depth image`` writes it at the image size instead.

COLOURS. flame3d shows raw.glb as its 3D view, so the mesh needs its colours. The app
colorizes a scan before any mesh export and writes the captured colours into mesh.obj
(``v x y z r g b``); those are used as they are. Exports from before that carry none, so
the mesh is coloured here from the frames instead: per vertex, the weighted median of its
best LiDAR-confirmed observations (see CaptureColors). Either way only real capture
colours are written, never the app's normals-based preview.

CHECK. After writing, the mesh is re-projected into a sample of frames through flame3d's
exact transform chain and scored against the high-confidence LiDAR: the share of measured
points within 2 cm of the mesh, as written and with the cameras nudged 5 cm each way.
Real rooms never score near 100% (glass, screens, people, the mesh's own bias), so the
test is relative: co-registered frames score best as written, while a wrong frame of
reference (a missing or mismatched registration.json, another scan's mesh) scores low
either way. It needs no flame3d install.

Requires numpy and Pillow:

    python3 scan4d_to_flame3d.py scan4d_Lab_Room_nerfstudio_....zip -o lab_room.zip
"""

from __future__ import annotations

import argparse
import io
import json
import re
import shutil
import struct
import sys
import tempfile
import zipfile
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

try:
    import numpy as np
    from PIL import Image
except ImportError as exc:  # pragma: no cover
    sys.exit(f"scan4d_to_flame3d needs numpy and Pillow (pip install numpy pillow): {exc}")

CONVERTER_VERSION = 1

# Small sidecars flame3d does not read yet but that describe the same scene: RoomPlan
# object boxes (canonical frame) and the registration record itself.
SIDECARS = ("registration.json", "roomplan.json")

# flame3d-core's transform chain, copied from data_processor/vendor_specific/polycam.py so
# the check reproduces exactly what the loader computes.
_YUP_TO_ZUP = np.array([[1, 0, 0, 0],
                        [0, 0, -1, 0],
                        [0, 1, 0, 0],
                        [0, 0, 0, 1]], dtype=np.float64)
_GL_TO_CV_CAM = np.diag([1.0, -1.0, -1.0, 1.0])

ASPECT_TOLERANCE = 0.01    # a still within 1% of the stream's aspect is resized to it
CHECK_FRAMES = 12          # frames with LiDAR the check samples, evenly spaced
CHECK_VERTICES = 200_000   # mesh vertices it projects per frame, randomly sampled
CHECK_TOL_M = 0.02         # a measured point "agrees" with the mesh within this
CHECK_EDGE_M = 0.10        # LiDAR pixels whose 3x3 neighbourhood spans more are skipped
CHECK_SHIFT_M = 0.05       # the nudge that probes whether a nearby frame fits better
CHECK_FLOOR = 0.05         # below this agreement, mesh and cameras are not co-framed
COLOR_KEEP = 8             # best observations kept per vertex for the colour median
COLOR_DEPTH_TOL_M = 0.05   # a vertex is visible in a frame within this (+2%) of its LiDAR
COLOR_FILL_RINGS = 3       # mesh-edge rings a seen colour may spread into unseen vertices:
                           # closes sampling gaps, never paints surfaces no frame saw


# ═══════════════════════════════════════════════════════════════════════════
# Bundle reading
# ═══════════════════════════════════════════════════════════════════════════

@dataclass
class Frame:
    stem: str
    image: Path
    depth: Path | None
    confidence: Path | None
    c2w: np.ndarray            # 4x4, ARKit raw frame, OpenGL camera axes
    fx: float
    fy: float
    cx: float
    cy: float
    width: int
    height: int
    kind: str = "stream"       # "stream" | "still" | "face"
    extras: dict = field(default_factory=dict)


def find_bundle_root(path: Path) -> Path:
    """The directory holding transforms.json: the bundle itself or one level down (a zip
    extracted with its top-level folder)."""
    if (path / "transforms.json").is_file():
        return path
    hits = sorted(path.glob("*/transforms.json"))
    if len(hits) == 1:
        return hits[0].parent
    if not hits:
        sys.exit(f"{path}: no transforms.json — is this a Scan4D *Nerfstudio* export?")
    sys.exit(f"{path}: several transforms.json found ({', '.join(str(h) for h in hits)})")


def load_frames(root: Path) -> list[Frame]:
    meta = json.loads((root / "transforms.json").read_text())
    raw_frames = meta.get("frames") or []
    if not raw_frames:
        sys.exit(f"{root}/transforms.json has no frames")

    def get(frame: dict, key: str):
        # Per-frame first, then the global block: a mixed-camera capture has no globals.
        return frame.get(key, meta.get(key))

    def sidecar(rel: str | None) -> Path | None:
        return root / rel if rel and (root / rel).is_file() else None

    frames: list[Frame] = []
    for entry in raw_frames:
        rel = entry["file_path"]
        image = root / rel
        if not image.is_file():
            print(f"  skip {rel}: image missing")
            continue
        w, h = get(entry, "w"), get(entry, "h")
        if w is None or h is None:
            with Image.open(image) as im:
                w, h = im.size
        intr = [get(entry, k) for k in ("fl_x", "fl_y", "cx", "cy")]
        if any(v is None for v in intr):
            sys.exit(f"{rel}: intrinsics missing from transforms.json")
        frames.append(Frame(
            stem=Path(rel).stem, image=image,
            depth=sidecar(entry.get("depth_file_path")),
            confidence=sidecar(entry.get("confidence_file_path")),
            c2w=np.array(entry["transform_matrix"], dtype=np.float64).reshape(4, 4),
            fx=float(intr[0]), fy=float(intr[1]), cx=float(intr[2]), cy=float(intr[3]),
            width=int(w), height=int(h),
            extras={k: entry[k] for k in ("is_keyframe", "sharpness", "face", "still_source",
                                          "camera_pose_source") if k in entry},
        ))

    # The 360° cube faces carry a "face" key. Of the rest, the most common size is the
    # video stream and anything else is a hi-res still.
    stream_size = Counter((f.width, f.height) for f in frames
                          if "face" not in f.extras).most_common(1)
    for f in frames:
        if "face" in f.extras:
            f.kind = "face"
        elif stream_size and (f.width, f.height) != stream_size[0][0]:
            f.kind = "still"
    frames.sort(key=lambda f: f.stem)
    return frames


def output_size(frames: list[Frame], max_size: int) -> tuple[int, int]:
    """The single output resolution: the stream frames' size, capped at max_size."""
    stream = [f for f in frames if f.kind == "stream"]
    ref = stream[0] if stream else frames[0]
    s = min(1.0, max_size / max(ref.width, ref.height))
    return max(1, round(ref.width * s)), max(1, round(ref.height * s))


def select_frames(frames: list[Frame], which: str, stride: int,
                  size: tuple[int, int]) -> tuple[list[Frame], dict[str, int]]:
    """The frames to write, in sequence order, and why the others were left out."""
    kinds = {"stream": {"stream"}, "stream+stills": {"stream", "still"}}[which]
    target_aspect = size[0] / size[1]
    out: list[Frame] = []
    dropped: Counter = Counter()
    stream_index = 0
    for f in frames:
        if f.kind not in kinds:
            dropped[f"{f.kind} (excluded)"] += 1
            continue
        if f.kind == "stream":
            stream_index += 1
            # Stride thins the video stream only: stills are the sharpest views there are.
            if (stream_index - 1) % stride:
                dropped["stream (stride)"] += 1
                continue
        if abs(f.width / f.height - target_aspect) > ASPECT_TOLERANCE * target_aspect:
            dropped[f"{f.kind} (aspect differs from the stream)"] += 1
            continue
        out.append(f)

    # normalize_labels orders by the stem's trailing integer and keys dicts by it, so a stem
    # without one crashes it and two stems sharing one silently merge.
    seen: dict[int, str] = {}
    for f in out:
        m = re.search(r"(\d+)$", f.stem)
        if m is None:
            sys.exit(f"{f.stem}: flame3d needs every image stem to end in a frame number")
        n = int(m.group(1))
        if n in seen:
            sys.exit(f"{f.stem} and {seen[n]} share frame number {n}; flame3d would merge them")
        seen[n] = f.stem
    out.sort(key=lambda f: int(re.search(r"(\d+)$", f.stem).group(1)))
    return out, dict(dropped)


def load_registration(root: Path) -> tuple[np.ndarray | None, dict | None]:
    """Row-major raw->canonical transform, or None when there is nothing to apply."""
    path = root / "registration.json"
    if not path.is_file():
        return None, None
    reg = json.loads(path.read_text())
    t = reg.get("transform")
    if not reg.get("applied") or not t or len(t) != 16:
        return None, reg
    return np.array(t, dtype=np.float64).reshape(4, 4).T, reg


# ═══════════════════════════════════════════════════════════════════════════
# Mesh: OBJ -> binary glTF
# ═══════════════════════════════════════════════════════════════════════════

def load_obj(path: Path) -> tuple[np.ndarray, np.ndarray, np.ndarray | None]:
    """Vertices (N,3) float64, triangles (M,3) int64, and per-vertex sRGB colours (N,3) in
    0-1 when every vertex carries them (``v x y z r g b``, how the app exports its captured
    colours), else None. Handles ``f a/b/c`` references, negative (relative) indices and
    polygons (fan-triangulated)."""
    verts: list[tuple[float, float, float]] = []
    rgb: list[tuple[float, float, float] | None] = []
    tris: list[tuple[int, int, int]] = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if line.startswith("v "):
                p = line.split()
                verts.append((float(p[1]), float(p[2]), float(p[3])))
                rgb.append((float(p[4]), float(p[5]), float(p[6])) if len(p) >= 7 else None)
            elif line.startswith("f "):
                idx = []
                for tok in line.split()[1:]:
                    i = int(tok.split("/", 1)[0])
                    idx.append(i - 1 if i > 0 else len(verts) + i)
                for k in range(1, len(idx) - 1):
                    tris.append((idx[0], idx[k], idx[k + 1]))
    if not verts or not tris:
        sys.exit(f"{path}: no vertices or faces parsed")
    colours = None if any(c is None for c in rgb) else np.clip(np.asarray(rgb, np.float32), 0, 1)
    return np.asarray(verts, dtype=np.float64), np.asarray(tris, dtype=np.int64), colours


def glb_bytes(vertices: np.ndarray, triangles: np.ndarray,
              colors_linear: np.ndarray | None = None) -> bytes:
    """One triangle-mesh primitive: positions, optional COLOR_0, uint32 indices, no material.
    glTF is Y-up by spec, which ARKit already is, so the vertices are written as they are.
    COLOR_0 is linear RGB by spec; flame3d's viewer switches vertex colours on when the
    attribute is present and the mesh has no texture."""
    arrays = [("POSITION", np.ascontiguousarray(vertices, dtype="<f4"), 34962)]
    if colors_linear is not None:
        arrays.append(("COLOR_0", np.ascontiguousarray(colors_linear, dtype="<f4"), 34962))
    arrays.append(("indices", np.ascontiguousarray(triangles, dtype="<u4").reshape(-1), 34963))

    binary, views, accessors, attributes = b"", [], [], {}
    for name, arr, target in arrays:
        views.append({"buffer": 0, "byteOffset": len(binary), "byteLength": arr.nbytes,
                      "target": target})
        binary += arr.tobytes()          # every array is 4-byte elements, so offsets align
        acc = {"bufferView": len(views) - 1, "count": len(arr)}
        if name == "indices":
            acc.update(componentType=5125, type="SCALAR")
        else:
            acc.update(componentType=5126, type="VEC3")
            attributes[name] = len(accessors)
        if name == "POSITION":
            acc.update(min=arr.min(axis=0).tolist(), max=arr.max(axis=0).tolist())
        accessors.append(acc)

    gltf = {
        "asset": {"version": "2.0", "generator": f"scan4d_to_flame3d v{CONVERTER_VERSION}"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0, "name": "scan4d_mesh"}],
        "meshes": [{"primitives": [{"attributes": attributes, "indices": len(accessors) - 1,
                                    "mode": 4}]}],
        "buffers": [{"byteLength": len(binary)}],
        "bufferViews": views,
        "accessors": accessors,
    }
    js = json.dumps(gltf, separators=(",", ":")).encode()
    js += b" " * (-len(js) % 4)
    binary += b"\0" * (-len(binary) % 4)
    total = 12 + 8 + len(js) + 8 + len(binary)
    return (struct.pack("<4sII", b"glTF", 2, total)
            + struct.pack("<I4s", len(js), b"JSON") + js
            + struct.pack("<I4s", len(binary), b"BIN\0") + binary)


# ═══════════════════════════════════════════════════════════════════════════
# Vertex colours from the captured frames
# ═══════════════════════════════════════════════════════════════════════════

def srgb_to_linear(c: np.ndarray) -> np.ndarray:
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


class CaptureColors:
    """Per-vertex RGB sampled from the captured frames, the way the app's colorize step does
    it: every frame projects the mesh, a vertex counts as seen only where it agrees with that
    frame's LiDAR depth (so occluded vertices never take the occluder's colour), each vertex
    keeps its COLOR_KEEP best observations weighted toward frontal, close views, and the
    result is their per-channel weighted median, which a few misregistered frames cannot drag.

    Only real capture colours come out of this. A vertex no frame saw takes the colour of
    seen neighbours at most COLOR_FILL_RINGS mesh edges away, which closes the gaps between
    samples; surfaces no frame saw stay mid-grey (no data, as in the app) and are counted."""

    def __init__(self, vertices: np.ndarray, triangles: np.ndarray, alignment: np.ndarray | None):
        self.alignment = alignment
        self.triangles = triangles
        self.vz = vertices @ _YUP_TO_ZUP[:3, :3].T
        fn = np.cross(self.vz[triangles[:, 1]] - self.vz[triangles[:, 0]],
                      self.vz[triangles[:, 2]] - self.vz[triangles[:, 0]])
        normals = np.zeros_like(self.vz)
        for k in range(3):
            np.add.at(normals, triangles[:, k], fn)          # area-weighted vertex normals
        self.normals = normals / np.maximum(np.linalg.norm(normals, axis=1, keepdims=True), 1e-12)
        n = len(vertices)
        self.obs_w = np.zeros((n, COLOR_KEEP), np.float32)
        self.obs_rgb = np.zeros((n, COLOR_KEEP, 3), np.float32)
        self.frames = 0

    def add(self, cam: dict, rgb: np.ndarray, depth_m: np.ndarray) -> None:
        """One frame: ``cam`` as written (intrinsics at ``rgb``'s size), ``depth_m`` at any
        raster covering the same view (the LiDAR's)."""
        c2w = flame3d_c2w(cam, self.alignment)
        w2c = np.linalg.inv(c2w)
        p = self.vz @ w2c[:3, :3].T + w2c[:3, 3]
        h, w = rgb.shape[:2]
        dh, dw = depth_m.shape
        # Nearest valid depth in each LiDAR pixel's 3x3 neighbourhood. One LiDAR pixel spans
        # several image pixels, so next to an occluder's edge the image can show the occluder
        # while the LiDAR pixel still reports the surface behind it.
        pad = np.pad(np.where(depth_m > 0, depth_m, np.inf), 1, mode="edge")
        windows = [pad[i:i + dh, j:j + dw] for i in range(3) for j in range(3)]
        nearest = np.min(windows, axis=0)
        # Privacy: the export zeroes person depth and pixelates person pixels, but at the
        # LiDAR's raster. A vertex next to a zeroed pixel may still land on a blurred person
        # pixel in the image, so require depth across the whole 3x3 neighbourhood — the
        # app's colorizer keeps the same one-mask-pixel margin around people.
        no_hole_nearby = np.all(np.isfinite(windows), axis=0)
        z = p[:, 2]
        idx = np.nonzero(z > 0.1)[0]
        u = cam["fx"] * p[idx, 0] / z[idx] + cam["cx"]
        v = cam["fy"] * p[idx, 1] / z[idx] + cam["cy"]
        inside = (u >= 0) & (u < w) & (v >= 0) & (v < h)
        idx, u, v = idx[inside], u[inside], v[inside]
        r, c = (v * dh / h).astype(int), (u * dw / w).astype(int)
        d = depth_m[r, c]
        zi = z[idx]
        seen = ((d > 0) & no_hole_nearby[r, c]
                & (np.abs(zi - d) < COLOR_DEPTH_TOL_M + 0.02 * d)
                & (nearest[r, c] > zi - np.maximum(COLOR_DEPTH_TOL_M, 0.1 * zi)))
        idx, u, v, zi = idx[seen], u[seen], v[seen], zi[seen]
        if not len(idx):
            return
        to_cam = c2w[:3, 3] - self.vz[idx]
        cos = np.abs(np.einsum("ij,ij->i", self.normals[idx], to_cam)) / np.linalg.norm(to_cam, axis=1)
        weight = (cos ** 2 / np.maximum(zi, 0.5) ** 2).astype(np.float32)
        colour = rgb[v.astype(int), u.astype(int)].astype(np.float32) / 255.0

        slot = self.obs_w[idx].argmin(axis=1)               # each vertex once per frame
        better = weight > self.obs_w[idx, slot]
        idx, slot = idx[better], slot[better]
        self.obs_w[idx, slot] = weight[better]
        self.obs_rgb[idx, slot] = colour[better]
        self.frames += 1

    def result(self) -> tuple[np.ndarray, dict]:
        """(sRGB colours in 0-1, stats)."""
        total = self.obs_w.sum(axis=1)
        seen = total > 0
        out = np.full((len(total), 3), 0.5, np.float32)
        for ch in range(3):
            vals = self.obs_rgb[:, :, ch]
            order = np.argsort(vals, axis=1)
            cum = np.cumsum(np.take_along_axis(self.obs_w, order, axis=1), axis=1)
            pick = (cum >= cum[:, -1:] / 2).argmax(axis=1)
            med = np.take_along_axis(np.take_along_axis(vals, order, axis=1), pick[:, None], axis=1)[:, 0]
            out[seen, ch] = med[seen]

        # Fill unseen vertices from seen neighbours, ring by ring across mesh edges.
        known = seen.copy()
        e = np.concatenate([self.triangles[:, [0, 1]], self.triangles[:, [1, 2]],
                            self.triangles[:, [2, 0]]])
        e = np.concatenate([e, e[:, ::-1]])
        for _ in range(COLOR_FILL_RINGS):
            live = known[e[:, 0]] & ~known[e[:, 1]]
            if not live.any():
                break
            src, dst = e[live, 0], e[live, 1]
            acc = np.zeros_like(out)
            cnt = np.zeros(len(out))
            np.add.at(acc, dst, out[src])
            np.add.at(cnt, dst, 1)
            grow = cnt > 0
            out[grow] = acc[grow] / cnt[grow, None]
            known |= grow
        n = len(out)
        return out, {"frames": self.frames, "seen": round(float(seen.sum()) / n, 4),
                     "filled_from_neighbours": round(float((known & ~seen).sum()) / n, 4),
                     "unseen_grey": round(float((~known).sum()) / n, 4)}


# ═══════════════════════════════════════════════════════════════════════════
# Per-frame conversion
# ═══════════════════════════════════════════════════════════════════════════

def convert_image(f: Frame, out_w: int, out_h: int) -> bytes:
    """JPEG bytes at (out_w, out_h) in the image's stored pixel layout — the layout the
    intrinsics describe. An EXIF orientation tag would make flame3d's cv2.imread rotate the
    pixels away from that layout, so such files are re-encoded without it."""
    with Image.open(f.image) as im:
        if im.size != (f.width, f.height):
            sys.exit(f"{f.image.name}: is {im.size[0]}x{im.size[1]}, transforms.json says "
                     f"{f.width}x{f.height}")
        oriented = im.getexif().get(0x0112, 1) != 1
        if im.format == "JPEG" and (out_w, out_h) == im.size and not oriented:
            return f.image.read_bytes()
        rgb = im.convert("RGB")
        if (out_w, out_h) != rgb.size:
            rgb = rgb.resize((out_w, out_h), Image.LANCZOS)
        buf = io.BytesIO()
        rgb.save(buf, "JPEG", quality=95)
        return buf.getvalue()


def read_png(path: Path) -> np.ndarray:
    with Image.open(path) as im:
        arr = np.array(im)
    if arr.ndim != 2:
        sys.exit(f"{path}: expected a single-channel PNG")
    return arr


def read_png_channel0(path: Path) -> np.ndarray:
    """Confidence maps are ARKit's 0/1/2 levels, stored greyscale or as identical RGB."""
    with Image.open(path) as im:
        arr = np.array(im)
    return arr if arr.ndim == 2 else arr[..., 0]


def resample_nearest(arr: np.ndarray, out_w: int, out_h: int) -> np.ndarray:
    """Nearest-neighbour, never bilinear (as NerfstudioExport.resampleDepth): interpolating
    across a depth edge would invent a surface at a range nothing measured. Sampling at
    output pixel centres makes the trip back down to the LiDAR raster exact even at the
    non-integer 1920/256 ratio, where corner sampling lands a row early every other row."""
    h, w = arr.shape
    if (w, h) == (out_w, out_h):
        return arr
    ys = ((2 * np.arange(out_h) + 1) * h) // (2 * out_h)
    xs = ((2 * np.arange(out_w) + 1) * w) // (2 * out_w)
    return arr[ys[:, None], xs[None, :]]


def png16_bytes(arr: np.ndarray) -> bytes:
    buf = io.BytesIO()
    Image.fromarray(np.ascontiguousarray(arr, dtype=np.uint16)).save(buf, "PNG")
    return buf.getvalue()


def lidar_sizes(frames: list[Frame], fallback: tuple[int, int]) -> dict[str, tuple[int, int]]:
    """Per stem, the LiDAR raster the bundle's depth was upsampled from: the confidence
    map's size, which NerfstudioExport leaves untouched. A frame without a confidence map
    (the first frame of a capture can lack one) takes the most common size."""
    sizes = {}
    for f in frames:
        if f.confidence is not None:
            with Image.open(f.confidence) as im:
                sizes[f.stem] = im.size
    common = Counter(sizes.values()).most_common(1)
    default = common[0][0] if common else fallback
    return {f.stem: sizes.get(f.stem, default) for f in frames}


def camera_json(f: Frame, out_w: int, out_h: int) -> dict:
    """Polycam camera record. Intrinsics scale with the image; the pose does not change."""
    sx, sy = out_w / f.width, out_h / f.height
    cam = {f"t_{r}{c}": float(f.c2w[r, c]) for r in range(3) for c in range(4)}
    cam.update({
        "fx": f.fx * sx, "fy": f.fy * sy, "cx": f.cx * sx, "cy": f.cy * sy,
        "width": out_w, "height": out_h,
        "blur_score": 1.0,
        "scan4d_kind": f.kind,
        "scan4d_source_size": [f.width, f.height],
    })
    cam.update(f.extras)
    return cam


# ═══════════════════════════════════════════════════════════════════════════
# Alignment check (flame3d's transform chain vs LiDAR)
# ═══════════════════════════════════════════════════════════════════════════

def flame3d_c2w(cam: dict, alignment: np.ndarray | None) -> np.ndarray:
    """What flame3d's _load_camera_json computes from one corrected_cameras record."""
    c2w = np.eye(4)
    for r in range(3):
        for c in range(4):
            c2w[r, c] = cam[f"t_{r}{c}"]
    if alignment is not None:
        c2w = alignment @ c2w
    return _YUP_TO_ZUP @ c2w @ _GL_TO_CV_CAM


def check_sample(cam: dict, depth_mm: np.ndarray, conf: np.ndarray | None) -> tuple[dict, np.ndarray]:
    """One frame for the check, at the LiDAR raster: the written camera record with its
    intrinsics rescaled to that raster, and depth in metres with the unreliable pixels
    zeroed — below ARKit's high confidence, and on depth edges, where a 256x192 pixel
    straddles two surfaces."""
    h, w = depth_mm.shape
    sx, sy = w / cam["width"], h / cam["height"]
    cam = dict(cam, fx=cam["fx"] * sx, fy=cam["fy"] * sy, cx=cam["cx"] * sx,
               cy=cam["cy"] * sy, width=w, height=h)
    d = without_depth_edges(depth_mm.astype(np.float32) / 1000.0)
    if conf is not None:
        d[conf < 2] = 0
    return cam, d


def without_depth_edges(d: np.ndarray) -> np.ndarray:
    """Depth (m) with every pixel zeroed whose 3x3 neighbourhood spans more than
    CHECK_EDGE_M or touches a missing value: at the LiDAR's coarse raster such a pixel
    straddles a foreground and a background surface, so it vouches for neither."""
    h, w = d.shape
    pad = np.pad(d, 1, mode="edge")
    win = np.stack([pad[i:i + h, j:j + w] for i in range(3) for j in range(3)])
    out = d.copy()
    out[(win.max(axis=0) - win.min(axis=0) > CHECK_EDGE_M) | (win.min(axis=0) <= 0)] = 0
    return out


def residuals(vertices_zup: np.ndarray, cam: dict, depth_m: np.ndarray,
              alignment: np.ndarray) -> np.ndarray:
    """Mesh depth minus measured depth for every vertex landing on a usable LiDAR pixel,
    projected exactly as flame3d's mesh_reprojection projects it."""
    w2c = np.linalg.inv(flame3d_c2w(cam, alignment))
    p = vertices_zup @ w2c[:3, :3].T + w2c[:3, 3]
    p = p[p[:, 2] > 0]
    u = cam["fx"] * p[:, 0] / p[:, 2] + cam["cx"]
    v = cam["fy"] * p[:, 1] / p[:, 2] + cam["cy"]
    h, w = depth_m.shape
    ok = (u >= 0) & (u < w) & (v >= 0) & (v < h)
    z, d = p[ok, 2], depth_m[v[ok].astype(int), u[ok].astype(int)]
    return z[d > 0] - d[d > 0]


def run_check(vertices: np.ndarray, samples: list[tuple[dict, np.ndarray]],
              alignment: np.ndarray | None) -> dict:
    """Score the share of measured points within CHECK_TOL_M of the mesh, as written and
    with the cameras nudged CHECK_SHIFT_M along each axis. A real scene keeps part of its
    LiDAR away from the mesh (glass, screens, people, the mesh's own bias), so no absolute
    score means "aligned"; but frames that are truly co-registered fit better as written
    than nudged, while a wrong frame of reference fits poorly either way."""
    if not samples:
        return {"skipped": "no frame has LiDAR depth with a confidence map"}
    rng = np.random.default_rng(0)
    if len(vertices) > CHECK_VERTICES:
        vertices = vertices[rng.choice(len(vertices), CHECK_VERTICES, replace=False)]
    vz = vertices @ _YUP_TO_ZUP[:3, :3].T
    base = alignment if alignment is not None else np.eye(4)

    def score(a: np.ndarray) -> tuple[float, int]:
        r = np.concatenate([residuals(vz, cam, d, a) for cam, d in samples])
        return (float(np.mean(np.abs(r) < CHECK_TOL_M)) if len(r) else 0.0), len(r)

    agree, points = score(base)
    if points < 1000:
        return {"skipped": f"only {points} mesh points landed on confident LiDAR pixels"}
    shifted = {}
    for axis, name in enumerate("xyz"):
        for sign in (1, -1):
            nudge = np.eye(4)
            nudge[axis, 3] = sign * CHECK_SHIFT_M
            shifted[f"{'+' if sign > 0 else '-'}{name}"] = score(nudge @ base)[0]
    report = {"frames": len(samples), "points": points, "tolerance_m": CHECK_TOL_M,
              "agree": agree, "shift_m": CHECK_SHIFT_M, "agree_shifted": shifted}
    if alignment is not None:
        report["agree_without_registration"] = score(np.eye(4))[0]
    return report


def describe_check(report: dict) -> list[str]:
    if "skipped" in report:
        return [f"check: skipped — {report['skipped']}"]
    agree, best = report["agree"], max(report["agree_shifted"].values())
    kind = "confident LiDAR points" if report.get("confidence_filtered", True) else "LiDAR points"
    lines = [(f"check: {agree:.0%} of {report['points']:,} {kind} on "
              f"{report['frames']} frames lie within {report['tolerance_m'] * 100:.0f} cm of the "
              f"mesh; nudging the cameras {report['shift_m'] * 100:.0f} cm scores at most "
              f"{best:.0%}")]
    without = report.get("agree_without_registration")
    if without is not None:
        lines.append(f"       without registration.json: {without:.0%}")
        if without > agree:
            lines.append("WARNING: the mesh fits the cameras better WITHOUT registration.json — "
                         "the sidecar may not belong to this mesh")
    if agree < CHECK_FLOOR or best > agree * 1.02:
        lines.append("WARNING: mesh and cameras are not in the same frame (another scan's mesh, "
                     "or a canonical-frame mesh without its registration.json?) — flame3d would "
                     "reproject the mesh onto the wrong pixels")
    return lines




# ═══════════════════════════════════════════════════════════════════════════
# Verifying a bundle (the converter's, or the app's Flame3D export)
# ═══════════════════════════════════════════════════════════════════════════

CAMERA_KEYS = [f"t_{r}{c}" for r in range(3) for c in range(4)] + [
    "fx", "fy", "cx", "cy", "width", "height"]


def read_glb(data: bytes) -> dict[str, np.ndarray]:
    """{"POSITION": (N,3), "COLOR_0": (N,3) if present, "indices": (M,3)} of the first
    primitive of a binary glTF with float32 attributes and uint32 indices."""
    magic, version, total = struct.unpack_from("<4sII", data, 0)
    if (magic, version, total) != (b"glTF", 2, len(data)):
        raise ValueError("not a glTF 2.0 binary of the stated length")
    jlen, jtype = struct.unpack_from("<I4s", data, 12)
    gltf = json.loads(data[20:20 + jlen])
    blen, btype = struct.unpack_from("<I4s", data, 20 + jlen)
    if (jtype, btype) != (b"JSON", b"BIN\0"):
        raise ValueError("unexpected glTF chunk types")
    binary = data[28 + jlen:28 + jlen + blen]
    acc, views = gltf["accessors"], gltf["bufferViews"]
    width = {"SCALAR": 1, "VEC3": 3}
    dtype = {5126: "<f4", 5125: "<u4"}

    def read(i):
        a = acc[i]
        arr = np.frombuffer(binary, dtype[a["componentType"]], a["count"] * width[a["type"]],
                            views[a["bufferView"]].get("byteOffset", 0))
        return arr.reshape(-1, width[a["type"]])

    prim = gltf["meshes"][0]["primitives"][0]
    out = {name: read(i) for name, i in prim["attributes"].items()}
    out["indices"] = read(prim["indices"]).reshape(-1, 3)
    return out


def verify_bundle(path: Path) -> tuple[list[str], dict]:
    """Check a flame3d bundle against what flame3d's polycam loader and pipeline need, and
    run the mesh-vs-LiDAR check on it. Returns (problems, info); no problems means flame3d
    can ingest it. Meant for the app's Flame3D export, which the converter's tests can't run."""
    problems: list[str] = []
    info: dict = {}
    tmp = None
    try:
        if path.is_file():
            with zipfile.ZipFile(path) as zf:
                names = zf.namelist()
                if not any(n.startswith("keyframes/images/") for n in names):
                    nested = sorted({n.split("/", 1)[0] for n in names if "/keyframes/images/" in n})
                    problems.append("no keyframes/ at the zip root" + (
                        f" (found under {', '.join(nested)}/ — flame3d extracts the zip as-is "
                        "and would not find it)" if nested else ""))
                    return problems, info
                tmp = Path(tempfile.mkdtemp(prefix="flame3d_verify_"))
                zf.extractall(tmp)
            root = tmp
        elif (path / "keyframes" / "images").is_dir():
            root = path
        else:
            return [f"{path}: no keyframes/images/ inside"], info

        kf = root / "keyframes"
        sets = {d: {p.stem for p in (kf / d).glob(f"*.{ext}")}
                for d, ext in (("images", "jpg"), ("corrected_cameras", "json"), ("depth", "png"))}
        if not sets["images"] == sets["corrected_cameras"] == sets["depth"]:
            problems.append("images/, corrected_cameras/ and depth/ hold different frames ("
                            + ", ".join(f"{d}: {len(s)}" for d, s in sets.items()) + ")")
        stems = sorted(sets["images"] & sets["corrected_cameras"] & sets["depth"])
        if not stems:
            return problems + ["no complete frames"], info

        numbers: dict[int, str] = {}
        image_sizes: Counter = Counter()
        depth_sizes: Counter = Counter()
        cams: dict[str, dict] = {}
        for s in stems:
            m = re.search(r"(\d+)$", s)
            if m is None:
                problems.append(f"{s}: no trailing frame number (flame3d's normalize_labels needs one)")
            elif int(m.group(1)) in numbers:
                problems.append(f"{s} and {numbers[int(m.group(1))]} share frame number {m.group(1)}")
            else:
                numbers[int(m.group(1))] = s
            cam = json.loads((kf / "corrected_cameras" / f"{s}.json").read_text())
            missing = [k for k in CAMERA_KEYS if k not in cam]
            if missing:
                problems.append(f"{s}: camera record lacks {', '.join(missing)}")
                continue
            with Image.open(kf / "images" / f"{s}.jpg") as im:
                if im.size != (cam["width"], cam["height"]):
                    problems.append(f"{s}: image {im.size[0]}x{im.size[1]}, camera says "
                                    f"{cam['width']}x{cam['height']}")
                if im.getexif().get(0x0112, 1) != 1:
                    problems.append(f"{s}: EXIF orientation set (cv2 would rotate the pixels)")
                image_sizes[im.size] += 1
            with Image.open(kf / "depth" / f"{s}.png") as d:
                if not d.mode.startswith("I"):
                    problems.append(f"{s}: depth PNG is {d.mode}, not 16-bit")
                depth_sizes[d.size] += 1
            cams[s] = cam
        if len(image_sizes) > 1:
            problems.append(f"{len(image_sizes)} image sizes {dict(image_sizes)}; SAM3 needs one")

        vertices = None
        if not (root / "raw.glb").is_file():
            problems.append("no raw.glb")
        else:
            try:
                glb = read_glb((root / "raw.glb").read_bytes())
                vertices = glb["POSITION"].astype(np.float64)
                info["mesh_vertices"] = len(vertices)
                info["vertex_colors"] = "COLOR_0" in glb
            except (ValueError, KeyError, struct.error) as exc:
                problems.append(f"raw.glb unreadable: {exc}")

        alignment = None
        try:
            flat = json.loads((root / "mesh_info.json").read_text())["alignmentTransform"]
            alignment = np.array(flat, dtype=np.float64).reshape(4, 4).T
            if np.allclose(alignment, np.eye(4)):
                alignment = None
        except (OSError, KeyError, ValueError) as exc:
            problems.append(f"mesh_info.json alignmentTransform unreadable: {exc}")

        info.update(frames=len(stems),
                    image_size=list(image_sizes.most_common(1)[0][0]) if image_sizes else None,
                    depth_raster=list(depth_sizes.most_common(1)[0][0]) if depth_sizes else None,
                    alignment_applied=alignment is not None)
        if vertices is not None and cams:
            with_depth = [s for s in cams
                          if read_png(kf / "depth" / f"{s}.png").astype(np.uint16).any()]
            every = max(1, len(with_depth) // CHECK_FRAMES)
            samples = [check_sample(cams[s], read_png(kf / "depth" / f"{s}.png").astype(np.uint16), None)
                       for s in with_depth[::every]]
            info["check"] = dict(run_check(vertices, samples, alignment), confidence_filtered=False)
        return problems, info
    finally:
        if tmp is not None:
            shutil.rmtree(tmp, ignore_errors=True)


def print_verify(path: Path) -> int:
    problems, info = verify_bundle(path)
    print(f"verify {path}")
    if "frames" in info:
        size = "x".join(map(str, info["image_size"] or []))
        raster = "x".join(map(str, info["depth_raster"] or []))
        colours = "with vertex colours" if info.get("vertex_colors") else "WITHOUT vertex colours"
        print(f"  frames: {info['frames']} at {size}; depth {raster}; mesh "
              f"{info.get('mesh_vertices', 0):,} vertices {colours}; "
              f"alignment {'applied' if info['alignment_applied'] else 'identity'}")
    if info.get("check"):
        for line in describe_check(info["check"]):
            print(line)
    if problems:
        print(f"{len(problems)} problem(s):")
        for p in problems[:20]:
            print(f"  - {p}")
        return 1
    print("OK: flame3d can ingest this bundle")
    return 0


# ═══════════════════════════════════════════════════════════════════════════
# Writer
# ═══════════════════════════════════════════════════════════════════════════

class Sink:
    """Writes into a zip, or into a directory when the output does not end in .zip."""

    def __init__(self, out: Path):
        self.out = out
        self.zip = None
        if out.suffix.lower() == ".zip":
            out.parent.mkdir(parents=True, exist_ok=True)
            self.zip = zipfile.ZipFile(out, "w", allowZip64=True)
        else:
            out.mkdir(parents=True, exist_ok=True)

    def write(self, rel: str, data: bytes) -> None:
        if self.zip is not None:
            # JPEG and PNG are already compressed; deflating them only costs time.
            stored = rel.endswith((".jpg", ".png"))
            self.zip.writestr(rel, data, zipfile.ZIP_STORED if stored else zipfile.ZIP_DEFLATED)
        else:
            path = self.out / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)

    def write_json(self, rel: str, obj) -> None:
        self.write(rel, json.dumps(obj, indent=2).encode())

    def close(self) -> None:
        if self.zip is not None:
            self.zip.close()


def convert(bundle: Path, out: Path, *, frames_mode: str = "stream+stills", stride: int = 1,
            max_size: int = 1920, depth_mode: str = "lidar", check: bool = True,
            colors: bool = True) -> dict:
    tmp = None
    try:
        if bundle.is_file() and bundle.suffix.lower() == ".zip":
            tmp = Path(tempfile.mkdtemp(prefix="scan4d_to_flame3d_"))
            with zipfile.ZipFile(bundle) as zf:
                zf.extractall(tmp)
            root = find_bundle_root(tmp)
        elif bundle.is_dir():
            root = find_bundle_root(bundle)
        else:
            sys.exit(f"{bundle}: not a directory or .zip")
        return _convert_root(root, bundle.name, out, frames_mode=frames_mode, stride=stride,
                             max_size=max_size, depth_mode=depth_mode, check=check,
                             colors=colors)
    finally:
        if tmp is not None:
            shutil.rmtree(tmp, ignore_errors=True)


def _convert_root(root: Path, source_name: str, out: Path, *, frames_mode: str, stride: int,
                  max_size: int, depth_mode: str, check: bool, colors: bool) -> dict:
    mesh_path = root / "mesh.obj"
    if not mesh_path.is_file():
        sys.exit(f"{root}: no mesh.obj — flame3d needs the scan mesh (re-export as Nerfstudio)")

    all_frames = load_frames(root)
    out_w, out_h = output_size(all_frames, max_size)
    frames, dropped = select_frames(all_frames, frames_mode, stride, (out_w, out_h))
    if not frames:
        sys.exit(f"no frames left after --frames {frames_mode} --stride {stride}")
    alignment, registration = load_registration(root)
    vertices, triangles, mesh_colours = load_obj(mesh_path)

    lidar = lidar_sizes(frames, (out_w, out_h))
    sink = Sink(out)
    check_every = max(1, sum(f.confidence is not None for f in frames) // CHECK_FRAMES)
    samples: list[tuple[dict, np.ndarray]] = []
    # The app's own captured colours when mesh.obj carries them; else sample the frames.
    colorizer = (CaptureColors(vertices, triangles, alignment)
                 if colors and mesh_colours is None else None)
    with_depth = with_confidence = 0
    try:
        for i, f in enumerate(frames, 1):
            cam = camera_json(f, out_w, out_h)
            jpg = convert_image(f, out_w, out_h)
            sink.write(f"keyframes/images/{f.stem}.jpg", jpg)
            sink.write_json(f"keyframes/corrected_cameras/{f.stem}.json", cam)

            # The bundle's depth is at the source image's size. The written file and the
            # check both want it back at the LiDAR raster (or the written file at the image's).
            source_depth = read_png(f.depth).astype(np.uint16) if f.depth is not None else None
            if source_depth is not None and not source_depth.any():
                source_depth = None          # an all-zero filler: no LiDAR for this frame
            if source_depth is not None:
                with_depth += 1
                if colorizer is not None:
                    lw, lh = lidar[f.stem]
                    with Image.open(io.BytesIO(jpg)) as im:
                        rgb = np.asarray(im.convert("RGB"))
                    colorizer.add(cam, rgb, resample_nearest(source_depth, lw, lh) / 1000.0)
            if source_depth is not None and f.confidence is not None:
                with_confidence += 1
                if (with_confidence - 1) % check_every == 0:
                    conf = read_png_channel0(f.confidence)
                    lw, lh = conf.shape[1], conf.shape[0]
                    samples.append(check_sample(cam, resample_nearest(source_depth, lw, lh), conf))
            dw, dh = lidar[f.stem] if depth_mode == "lidar" else (out_w, out_h)
            written = (resample_nearest(source_depth, dw, dh) if source_depth is not None
                       else np.zeros((dh, dw), np.uint16))
            # flame3d only uses frames that have a depth PNG, so every frame gets one.
            sink.write(f"keyframes/depth/{f.stem}.png", png16_bytes(written))
            if i % 50 == 0 or i == len(frames):
                print(f"  frames {i}/{len(frames)}", flush=True)

        color_stats = None
        if colors and mesh_colours is not None:
            color_stats = {"source": "mesh.obj"}
            sink.write("raw.glb", glb_bytes(vertices, triangles, srgb_to_linear(mesh_colours)))
        elif colorizer is not None:
            srgb, stats = colorizer.result()
            color_stats = {"source": "frames", **stats}
            sink.write("raw.glb", glb_bytes(vertices, triangles, srgb_to_linear(srgb)))
        else:
            sink.write("raw.glb", glb_bytes(vertices, triangles))

        flat = (alignment if alignment is not None else np.eye(4)).T.reshape(-1).tolist()
        sink.write_json("mesh_info.json", {
            "alignmentTransform": flat,          # column-major, as Polycam and flame3d read it
            "num_frames": len(frames),
            "image_width": out_w,
            "image_height": out_h,
            "coordinate_system": "arkit",
        })

        for name in SIDECARS:
            if (root / name).is_file():
                sink.write(f"scan4d/{name}", (root / name).read_bytes())

        report = run_check(vertices, samples, alignment) if check else None
        summary = {
            "converter": "scan4d_to_flame3d",
            "converter_version": CONVERTER_VERSION,
            "source": source_name,
            "options": {"frames": frames_mode, "stride": stride, "max_size": max_size,
                        "depth": depth_mode},
            "image_size": [out_w, out_h],
            "frames_in": dict(Counter(f.kind for f in all_frames)),
            "frames_out": dict(Counter(f.kind for f in frames)),
            "frames_dropped": dropped,
            "frames_out_with_lidar": with_depth,
            "mesh": {"vertices": len(vertices), "triangles": len(triangles),
                     "colors": color_stats},
            "registration": None if registration is None else {
                "applied": alignment is not None,
                "reason": registration.get("reason"),
                "translation_cm": None if alignment is None
                else round(100 * float(np.linalg.norm(alignment[:3, 3])), 2),
                "yaw_deg": registration.get("yawDeg"),
            },
            "check": report,
        }
        sink.write_json("scan4d/conversion.json", summary)
    finally:
        sink.close()
    return summary


# ═══════════════════════════════════════════════════════════════════════════
# CLI
# ═══════════════════════════════════════════════════════════════════════════

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="Convert a Scan4D Nerfstudio export (.zip or folder) into a flame3d-core "
                    "'polycam' input bundle.")
    ap.add_argument("bundle", type=Path,
                    help="Scan4D Nerfstudio export (.zip or folder); with --verify, a flame3d bundle")
    ap.add_argument("--verify", action="store_true",
                    help="check an existing flame3d bundle (e.g. the app's Flame3D export) "
                         "instead of converting; exits non-zero if flame3d couldn't ingest it")
    ap.add_argument("-o", "--out", type=Path, default=None,
                    help="output .zip (default: <bundle>_flame3d.zip next to the input); a path "
                         "not ending in .zip writes an unpacked folder instead")
    ap.add_argument("--frames", choices=["stream", "stream+stills"], default="stream+stills",
                    help="keep the hi-res stills (resized to the stream size) or the video "
                         "stream alone; 360° cube faces are never written (default: stream+stills)")
    ap.add_argument("--stride", type=int, default=1,
                    help="keep every Nth video-stream frame; stills are always kept (default: 1)")
    ap.add_argument("--max-size", type=int, default=1920,
                    help="cap on the output long edge in pixels; never upscales (default: 1920)")
    ap.add_argument("--depth", choices=["lidar", "image"], default="lidar",
                    help="write depth at the LiDAR's raster, like Polycam, or at the image size "
                         "(default: lidar)")
    ap.add_argument("--no-colors", action="store_true",
                    help="write the mesh without vertex colours (skips sampling them from the frames)")
    ap.add_argument("--no-check", action="store_true",
                    help="skip the mesh-vs-LiDAR alignment check")
    args = ap.parse_args(argv)

    if args.verify:
        return print_verify(args.bundle)
    if args.stride < 1 or args.max_size < 16:
        ap.error("--stride must be >= 1 and --max-size >= 16")
    out = args.out or args.bundle.with_name(
        (args.bundle.stem if args.bundle.suffix.lower() == ".zip" else args.bundle.name)
        + "_flame3d.zip")

    summary = convert(args.bundle, out, frames_mode=args.frames, stride=args.stride,
                      max_size=args.max_size, depth_mode=args.depth, check=not args.no_check,
                      colors=not args.no_colors)

    fo = summary["frames_out"]
    w, h = summary["image_size"]
    print(f"wrote {out}")
    print(f"  frames: {sum(fo.values())} at {w}x{h} "
          f"({', '.join(f'{v} {k}' for k, v in fo.items())})")
    for why, n in summary["frames_dropped"].items():
        print(f"  dropped {n} {why}")
    print(f"  mesh: {summary['mesh']['vertices']:,} vertices, "
          f"{summary['mesh']['triangles']:,} triangles")
    cs = summary["mesh"]["colors"]
    if cs is not None and cs["source"] == "mesh.obj":
        print("  colours: the app's captured colours, from mesh.obj")
    elif cs is not None:
        print(f"  colours: sampled from {cs['frames']} frames; {cs['seen']:.0%} of vertices seen, "
              f"{cs['filled_from_neighbours']:.0%} filled from neighbours, "
              f"{cs['unseen_grey']:.1%} left grey")
    reg = summary["registration"]
    if reg is None:
        print("  alignment: identity (no registration.json — mesh and cameras share a frame)")
    elif reg["applied"]:
        print(f"  alignment: registration.json ({reg['translation_cm']} cm, "
              f"yaw {reg['yaw_deg']}°)")
    else:
        print(f"  alignment: identity (registration.json not applied: {reg['reason']})")
    if summary["check"] is not None:
        for line in describe_check(summary["check"]):
            print(line)
    print('next: flame3d-core/scripts/start_pipeline.sh --data '
          f'{out} --config <config with "data_source": "polycam"> --wait')
    return 0


if __name__ == "__main__":
    sys.exit(main())
