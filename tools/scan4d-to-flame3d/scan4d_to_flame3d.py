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
    ├── raw.glb                            mesh.obj as binary glTF (canonical frame, Y-up)
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

def load_obj(path: Path) -> tuple[np.ndarray, np.ndarray]:
    """Vertices (N,3) float64 and triangles (M,3) int64. Handles ``f a/b/c`` references,
    negative (relative) indices and polygons (fan-triangulated)."""
    verts: list[tuple[float, float, float]] = []
    tris: list[tuple[int, int, int]] = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if line.startswith("v "):
                p = line.split()
                verts.append((float(p[1]), float(p[2]), float(p[3])))
            elif line.startswith("f "):
                idx = []
                for tok in line.split()[1:]:
                    i = int(tok.split("/", 1)[0])
                    idx.append(i - 1 if i > 0 else len(verts) + i)
                for k in range(1, len(idx) - 1):
                    tris.append((idx[0], idx[k], idx[k + 1]))
    if not verts or not tris:
        sys.exit(f"{path}: no vertices or faces parsed")
    return np.asarray(verts, dtype=np.float64), np.asarray(tris, dtype=np.int64)


def glb_bytes(vertices: np.ndarray, triangles: np.ndarray) -> bytes:
    """One triangle-mesh primitive, positions + uint32 indices, no material. glTF is Y-up
    by spec, which ARKit already is, so the vertices are written as they are."""
    pos = np.ascontiguousarray(vertices, dtype="<f4")
    idx = np.ascontiguousarray(triangles, dtype="<u4")
    pos_b, idx_b = pos.tobytes(), idx.tobytes()
    gltf = {
        "asset": {"version": "2.0", "generator": f"scan4d_to_flame3d v{CONVERTER_VERSION}"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0, "name": "scan4d_mesh"}],
        "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1, "mode": 4}]}],
        "buffers": [{"byteLength": len(pos_b) + len(idx_b)}],
        "bufferViews": [
            {"buffer": 0, "byteOffset": 0, "byteLength": len(pos_b), "target": 34962},
            {"buffer": 0, "byteOffset": len(pos_b), "byteLength": len(idx_b), "target": 34963},
        ],
        "accessors": [
            {"bufferView": 0, "componentType": 5126, "count": len(pos), "type": "VEC3",
             "min": pos.min(axis=0).tolist(), "max": pos.max(axis=0).tolist()},
            {"bufferView": 1, "componentType": 5125, "count": idx.size, "type": "SCALAR"},
        ],
    }
    js = json.dumps(gltf, separators=(",", ":")).encode()
    js += b" " * (-len(js) % 4)
    binary = pos_b + idx_b
    binary += b"\0" * (-len(binary) % 4)
    total = 12 + 8 + len(js) + 8 + len(binary)
    return (struct.pack("<4sII", b"glTF", 2, total)
            + struct.pack("<I4s", len(js), b"JSON") + js
            + struct.pack("<I4s", len(binary), b"BIN\0") + binary)


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
    d = depth_mm.astype(np.float32) / 1000.0
    pad = np.pad(d, 1, mode="edge")
    win = np.stack([pad[i:i + h, j:j + w] for i in range(3) for j in range(3)])
    d[(win.max(axis=0) - win.min(axis=0) > CHECK_EDGE_M) | (win.min(axis=0) <= 0)] = 0
    if conf is not None:
        d[conf < 2] = 0
    return cam, d


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
    lines = [(f"check: {agree:.0%} of {report['points']:,} confident LiDAR points on "
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
            max_size: int = 1920, depth_mode: str = "lidar", check: bool = True) -> dict:
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
                             max_size=max_size, depth_mode=depth_mode, check=check)
    finally:
        if tmp is not None:
            shutil.rmtree(tmp, ignore_errors=True)


def _convert_root(root: Path, source_name: str, out: Path, *, frames_mode: str, stride: int,
                  max_size: int, depth_mode: str, check: bool) -> dict:
    mesh_path = root / "mesh.obj"
    if not mesh_path.is_file():
        sys.exit(f"{root}: no mesh.obj — flame3d needs the scan mesh (re-export as Nerfstudio)")

    all_frames = load_frames(root)
    out_w, out_h = output_size(all_frames, max_size)
    frames, dropped = select_frames(all_frames, frames_mode, stride, (out_w, out_h))
    if not frames:
        sys.exit(f"no frames left after --frames {frames_mode} --stride {stride}")
    alignment, registration = load_registration(root)
    vertices, triangles = load_obj(mesh_path)

    lidar = lidar_sizes(frames, (out_w, out_h))
    sink = Sink(out)
    check_every = max(1, sum(f.confidence is not None for f in frames) // CHECK_FRAMES)
    samples: list[tuple[dict, np.ndarray]] = []
    with_depth = with_confidence = 0
    try:
        for i, f in enumerate(frames, 1):
            cam = camera_json(f, out_w, out_h)
            sink.write(f"keyframes/images/{f.stem}.jpg", convert_image(f, out_w, out_h))
            sink.write_json(f"keyframes/corrected_cameras/{f.stem}.json", cam)

            # The bundle's depth is at the source image's size. The written file and the
            # check both want it back at the LiDAR raster (or the written file at the image's).
            source_depth = read_png(f.depth).astype(np.uint16) if f.depth is not None else None
            if source_depth is not None and not source_depth.any():
                source_depth = None          # an all-zero filler: no LiDAR for this frame
            if source_depth is not None:
                with_depth += 1
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
            "mesh": {"vertices": len(vertices), "triangles": len(triangles)},
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
    ap.add_argument("bundle", type=Path, help="Scan4D Nerfstudio export: the .zip or its folder")
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
    ap.add_argument("--no-check", action="store_true",
                    help="skip the mesh-vs-LiDAR alignment check")
    args = ap.parse_args(argv)

    if args.stride < 1 or args.max_size < 16:
        ap.error("--stride must be >= 1 and --max-size >= 16")
    out = args.out or args.bundle.with_name(
        (args.bundle.stem if args.bundle.suffix.lower() == ".zip" else args.bundle.name)
        + "_flame3d.zip")

    summary = convert(args.bundle, out, frames_mode=args.frames, stride=args.stride,
                      max_size=args.max_size, depth_mode=args.depth, check=not args.no_check)

    fo = summary["frames_out"]
    w, h = summary["image_size"]
    print(f"wrote {out}")
    print(f"  frames: {sum(fo.values())} at {w}x{h} "
          f"({', '.join(f'{v} {k}' for k, v in fo.items())})")
    for why, n in summary["frames_dropped"].items():
        print(f"  dropped {n} {why}")
    print(f"  mesh: {summary['mesh']['vertices']:,} vertices, "
          f"{summary['mesh']['triangles']:,} triangles")
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
