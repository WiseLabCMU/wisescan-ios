# Scan4D → flame3d-core

[flame3d-core](https://github.com/openflam/flame3d-core) turns a 3D capture into a queryable scene: it
finds objects in every frame with a VLM, tracks them with SAM3, lifts the masks onto the
mesh, and stores captioned, CLIP-embedded 3D components in PostGIS for spatial, semantic and
LLM search. `scan4d_to_flame3d.py` converts a Scan4D **Nerfstudio** export into the input
flame3d's existing **`polycam`** data source reads, so a Scan4D capture runs through flame3d
with no flame3d change.

The app now writes this bundle itself: the **Flame3D** export format (`Flame3DExport.swift`)
follows the contract below. This script stays for Nerfstudio exports, and `--verify` checks
any bundle, the app's included, before you upload it:

```bash
python3 scan4d_to_flame3d.py --verify scan4d_Lab_Room_flame3d_....zip
```

```bash
pip install numpy pillow
python3 scan4d_to_flame3d.py scan4d_Lab_Room_nerfstudio_....zip -o lab_room.zip
# then, on the flame3d box (stack running):
scripts/start_pipeline.sh --data lab_room.zip --config my_config.json --wait
```

`my_config.json` is flame3d's `server/default_config.json` with `"data_source": "polycam"`
and your `dataset_name`. See [flame3d settings](#flame3d-settings-worth-knowing) for two
values worth knowing.

The input is the Nerfstudio export as a `.zip` or an unpacked `staging_*` folder. The Scan4D
and Polycam exports don't work: neither carries `mesh.obj`, and flame3d needs the mesh. Pass
`-o some_dir` without `.zip` to get an unpacked folder for inspection.

| Option | Default | Effect |
|---|---|---|
| `--frames stream+stills` / `stream` | `stream+stills` | Keep the hi-res stills, resized to the stream size, or drop them |
| `--stride N` | 1 | Keep every Nth video-stream frame. Stills are always kept. flame3d makes one VLM call per frame. |
| `--max-size PX` | 1920 | Cap on the output long edge. Never upscales. |
| `--depth lidar` / `image` | `lidar` | Depth at the LiDAR raster (as Polycam ships it) or at the image size |
| `--no-colors` | off | Write the mesh without vertex colors (skips sampling them from the frames) |
| `--no-check` | off | Skip the mesh-vs-LiDAR frame check |

## The bundle

This is the contract a future in-app "flame3d" export should produce. Every entry is a change
of representation of something the Nerfstudio export already holds.

```
input.zip                                   (entries at the root; flame3d extracts as-is)
├── keyframes/
│   ├── images/<stem>.jpg                   one resolution for every frame, lowercase .jpg
│   ├── corrected_cameras/<stem>.json       Polycam camera record (below)
│   └── depth/<stem>.png                    16-bit mm, LiDAR raster; zeros where none
├── raw.glb                                 mesh.obj as binary glTF, unchanged coordinates,
│                                           with vertex colors sampled from the frames
├── mesh_info.json                          alignmentTransform + Polycam summary fields
└── scan4d/
    ├── conversion.json                     options, frame counts, check result
    ├── registration.json, roomplan.json    copied when present; flame3d ignores them today
```

| flame3d reads | Written from | Notes |
|---|---|---|
| `t_00`…`t_23` | `transform_matrix` rows 0–2 | Camera-to-world, row-major, ARKit **raw** frame, OpenGL camera axes. Passed through. |
| `fx fy cx cy width height` | per-frame `fl_x fl_y cx cy w h` | Scaled by the resize factor when a frame is downscaled |
| `alignmentTransform` | `registration.json` `transform` | Column-major raw→canonical, verbatim. Identity when the sidecar is absent or not applied. |
| `raw.glb` | `mesh.obj` + the frames | Canonical frame, Y-up (glTF's convention and ARKit's). Positions, indices, and `COLOR_0` (float RGB, linear as glTF requires) sampled from the frames. No material or texture. |
| `depth/<stem>.png` | `depth/` | Nearest-neighbour back down to the confidence map's raster |

**Frames of reference.** flame3d computes `c2w = alignmentTransform @ c2w`. It then rotates
Y-up to Z-up and flips the camera axes from OpenGL to OpenCV
(`data_processor/vendor_specific/polycam.py`). Our cameras are raw-frame and `mesh.obj` is
canonical-frame. `registration.json` holds raw→canonical in the same column-major encoding
`alignmentTransform` uses, so the converter passes it through and re-expresses nothing.

**Why this frame selection.** These are flame3d-core assumptions, checked at `c8e1595`:

- **Frames are a video.** `normalize_labels` orders frames by the trailing integer of the
  stem and builds runs of consecutive frames. SAM3's video predictor tracks objects through
  each run.
- **Stream frames and stills are kept.** They share one temporal `frame_NNNNN` sequence.
- **Cube faces are never written.** Their stems end in a face name, which raises a
  `ValueError` in `normalize_labels`. They sort after the whole stream and jump 90° from
  face to face, so no ordering of them tracks.
- **Stems are validated.** The converter refuses a stem without a trailing frame number,
  and two stems that share one.
- **One resolution.** A SAM3 run is loaded as one video. A mask whose size differs from its
  image is skipped by `associate2d3d` and raises `IndexError` in `mask_graph`.
- **Stills are resized to exactly the stream size.** Their intrinsics are scaled to match.
  A still with a different aspect ratio is dropped.
- **No EXIF orientation.** An orientation tag would make `cv2.imread` rotate the pixels away
  from the layout the intrinsics describe, so such images are re-encoded without it.

**Why depth at the LiDAR raster.** flame3d renders depth from the mesh
(`use_rendered_depth=True`) and only needs each frame to have a readable depth PNG. It
still holds every map in RAM as float32: 11 MB per frame at 1920×1440, 0.2 MB at 256×192.
The Nerfstudio export upsampled depth nearest-neighbour to the image size. Sampling it back
down at pixel centres recovers the measured values exactly, and the tests assert this.

## Vertex colors

flame3d shows `raw.glb` as its 3D view. Its viewer uses a texture when the GLB has one and
per-vertex colors (`COLOR_0`) otherwise, so an uncolored mesh shows up gray.

The app colorizes a scan before any mesh export and writes the captured colors into the
Nerfstudio export's `mesh.obj` as `v x y z r g b`. The converter uses those as they are
(`colors: {"source": "mesh.obj"}` in `conversion.json`). Exports made before that carry no
color, so for them the converter samples it from the captured frames, the way the app's
colorize step does:

1. **Project.** Every frame with LiDAR projects the mesh through flame3d's camera math.
2. **Visibility.** A vertex counts as seen only where it agrees with that frame's LiDAR depth,
   and no much-closer surface sits in the neighboring LiDAR pixels. One LiDAR pixel spans
   about 7.5 image pixels, so without the second test a wall vertex beside a table edge
   picks up the table's color.
3. **Privacy.** The export pixelates people and zeroes their depth. A vertex also needs depth
   in every LiDAR pixel around it, so blurred person pixels at a silhouette never color the
   mesh. That's the same one-pixel margin the app's colorizer keeps around its person masks.
4. **Median.** Each vertex keeps its 8 best observations, weighted toward frontal and close
   views, and takes their per-channel weighted median. A few misregistered frames can't
   drag it.
5. **Gaps.** A seen color may spread at most 3 mesh edges into unseen vertices, closing gaps
   between samples. Surfaces no frame saw stay mid-gray, meaning no data.

Only real capture colors are written. The app's `colors.bin` holds normals-based preview
colors until the scan is colorized, and those never go into an export.

On `staging_14D76B3E`, 95% of vertices are seen, 3% are filled from neighbors, and 2.4% stay
gray. Coloring the mesh from 7/8 of the frames and comparing with the held-out 1/8, the
predicted colors are a median 13/255 off the real pixels, against 49/255 for the frame's
mean color. Much of what remains is the camera's auto-exposure varying between frames.

## The check

The converter re-projects the mesh into about 12 frames through flame3d's exact transform
chain. It then scores the share of high-confidence LiDAR points within 2 cm of the mesh,
skipping depth edges. It scores once as written, and once with the cameras nudged 5 cm
along each axis.

```
check: 22% of 196,870 confident LiDAR points on 13 frames lie within 2 cm of the mesh;
       nudging the cameras 5 cm scores at most 18%
```

A real room never scores near 100%. Glass, screens, people and the mesh's own centimetre
bias all keep LiDAR off the mesh; on `staging_14D76B3E`, some frames score 1% "in front" and
others 50%. So the test is relative. Co-registered frames score best as written. A wrong
frame of reference scores low either way and prints a `WARNING`. Causes include another
scan's mesh, or a canonical mesh without its `registration.json`. A 30 cm camera offset on
the same capture scores 7% against 8% nudged, and warns.

## Tests

`tests/` builds a synthetic Nerfstudio export with exactly known geometry: a box room with
a table, a raw→canonical registration, stream frames, hi-res stills (one at 16:9) and cube
faces.

```bash
# numpy + Pillow + pytest; the end-to-end test also needs open3d + OpenCV and a flame3d-core
# checkout, and skips without them
FLAME3D_CORE=../../../flame3d-core python -m pytest tests -q
```

- **Unit tests (`test_convert.py`).** They cover frame selection and the stem rules,
  intrinsics scaling, alignment pass-through, the GLB round-trip, exact LiDAR recovery,
  EXIF stripping, zip and folder I/O, and the check in both directions. They also check
  the vertex colors: every vertex a frame saw has the scene's true color (off checker and
  silhouette edges), unseen surfaces stay gray, and the GLB carries exactly those colors.
- **End-to-end test (`test_flame3d_e2e.py`).** It runs flame3d-core's own `process_polycam`
  on the converted bundle: extract, load, Y-up→Z-up, mesh ray-cast, COLMAP. It asserts that
  flame3d's mesh-rendered depth equals the analytic depth: median under 1 mm, more than 97%
  of pixels within 1 cm, on every frame. Dropping `registration.json` must break that, and
  it does. This step runs on the CPU. Everything after it needs the GPU stack.

A CPU image that runs everything:

```dockerfile
FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends libgomp1 libgl1 libegl1 \
    libusb-1.0-0 libidn2-0 libtbb12 libglib2.0-0 && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir numpy pillow pytest opencv-python-headless tqdm scipy open3d-cpu
```

## On a real capture

`staging_14D76B3E` has 139 stream frames and 21 stills (4032×3024), and a 270k-vertex mesh.

- **Conversion.** About 10 s, giving a 151 MB zip with 160 frames at 1920×1440. Sampling
  the vertex colors adds roughly another 10 s.
- **flame3d's `polycam_process`.** 22 s on CPU, with every frame observing mesh vertices.
- **Depth agreement.** flame3d's own mesh-rendered depth sits at a median of −1.0 cm from
  the phone's high-confidence LiDAR, with 71% of pixels within 5 cm. The −1 cm is the ARKit
  mesh bias `meshrender.py --debias` measures. Frames 10–30 are worse: scene content, the
  same run of frames the check shows.

## flame3d settings worth knowing

- **`polycam.depth_tolerance`.** Shipped as `0.0001`, which is relative: 0.2 mm at 2 m. A
  mesh vertex counts as seen only when the pixel ray it lands on hits the surface that
  close. At 1920×1440 that still works: 69% of the mesh is observed, and the median frame
  sees 8.2k vertices. `0.01` raises that to 82% and 20.8k. At the synthetic tests' 192 px,
  0.0001 leaves only 7%.
- **`identify_objects.max_frames`.** It samples frames uniformly before the VLM pass, which
  makes one API call per frame. `--stride` does the same at conversion time.

## In the app: the Flame3D export

`Flame3DExport.swift` writes the bundle above from the same data the other exports stage.
Keep it and this script in step:

- **Frames.** It starts from the staged Polycam payload, after the export-time privacy
  passes, so people are already pixelated and their depth zeroed. It keeps the stream frames
  and stills, resizing stills to the stream size and scaling their intrinsics. It skips the
  cube faces and any still whose aspect ratio differs from the stream's.
- **Depth.** The LiDAR depth at its native raster, unchanged.
- **Mesh.** `raw.glb` from `mesh.obj`, with `COLOR_0` from `colors.bin` converted to linear.
  Like every mesh export, it colorizes the scan first if needed, so the colors are captured
  ones, never the normals preview.
- **Alignment.** `alignmentTransform` from the registration sidecar.
- **Archive.** Its own uncompressed zip with the entries at the root. The app's usual
  directory zip puts the folder itself at the top, and flame3d would not find `keyframes/`.

Cube faces are a planned follow-up. To use them without breaking flame3d, each face would
need cropping to the stream's aspect and size, and frame numbers in blocks after the
stream.
