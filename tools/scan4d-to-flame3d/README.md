# Scan4D → flame3d-core

[flame3d-core](https://github.com/openflam/flame3d-core) turns a 3D capture into a queryable scene: it
finds objects in every frame with a VLM, tracks them with SAM3, lifts the masks onto the
mesh, and stores captioned, CLIP-embedded 3D components in PostGIS for spatial, semantic and
LLM search. `scan4d_to_flame3d.py` converts a Scan4D **Nerfstudio** export into the input
flame3d's existing **`polycam`** data source reads, so a Scan4D capture runs through flame3d
with no flame3d change.

```bash
pip install numpy pillow
python3 scan4d_to_flame3d.py scan4d_Lab_Room_nerfstudio_....zip -o lab_room.zip
# then, on the flame3d box (stack running):
scripts/start_pipeline.sh --data lab_room.zip --config my_config.json --wait
```

`my_config.json` is flame3d's `server/default_config.json` with `"data_source": "polycam"`
and your `dataset_name`. See [flame3d settings](#flame3d-settings-worth-changing) for two
values worth changing.

The input is the Nerfstudio export as a `.zip` or an unpacked `staging_*` folder. The Scan4D
and Polycam exports don't work: neither carries `mesh.obj`, and flame3d needs the mesh. Pass
`-o some_dir` without `.zip` to get an unpacked folder for inspection.

| Option | Default | Effect |
|---|---|---|
| `--frames stream+stills` / `stream` | `stream+stills` | Keep the hi-res stills, resized to the stream size, or drop them |
| `--stride N` | 1 | Keep every Nth video-stream frame. Stills are always kept. flame3d makes one VLM call per frame. |
| `--max-size PX` | 1920 | Cap on the output long edge. Never upscales. |
| `--depth lidar` / `image` | `lidar` | Depth at the LiDAR raster (as Polycam ships it) or at the image size |
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
├── raw.glb                                 mesh.obj as binary glTF, unchanged coordinates
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
| `raw.glb` | `mesh.obj` | Canonical frame, Y-up (glTF's convention and ARKit's). Positions and indices only. |
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
  EXIF stripping, zip and folder I/O, and the check in both directions.
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

- **Conversion.** About 10 s, giving a 148 MB zip with 160 frames at 1920×1440.
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

## Toward an in-app export

The bundle above is the format contract. Every step is a cheap re-layout of data the app
already stages for the Nerfstudio export:

- **Frames.** Copy `images/`, and rename `cameras/*.json` to `corrected_cameras/`. Resize
  the 12 MP stills to the stream size and scale their intrinsics. Skip the cube faces.
- **Depth.** Ship the LiDAR depth at its native raster, which skips the upsample.
- **Mesh.** Write a minimal GLB from `mesh.obj`: positions and indices, as `glb_bytes()`
  does in about 40 lines. `colors.bin` could add `COLOR_0` for flame3d's viewer.
- **Alignment.** Write `alignmentTransform` from the registration sidecar.

The alternative is a native `scan4d` data source in flame3d-core, which reads the
Nerfstudio export directly. That touches about six flame3d files (`pipeline_steps.py`,
`data_process.py`, `config_schema.json`, `default_config.json`, `routes/processing.py` and
a new loader). Today's path needs neither repo to change.
