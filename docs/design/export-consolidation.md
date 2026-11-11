# Design: One Capture Export, Formats Made on the Server

**Status:** Implemented (2026-11-09)
**Scope:** The app's export formats, and where the layouts other tools read are made.

## Decision

The app exports one capture bundle, **Scan4D**, plus three single-file meshes (OBJ, PLY,
USDZ). Scan4D now carries everything the scan captured, the mesh with its captured colors and
`face_classes.bin` included. The **Polycam**, **Nerfstudio** (formerly RAW) and **Flame3D**
exports are gone from the app. Each was the same data in another layout, so the lab server now
makes those layouts from the Scan4D export, in the flows repo (scan4d-flows, the
`prefect-server` folder).

| Was an app export | Now |
|---|---|
| Polycam | A strict subset of Scan4D, at the same paths. Dropped. |
| Nerfstudio | `scan4d-normalize` builds the dataset from the export. `scan4d-convert target=nerfstudio` zips it, and `scan4d-splat` trains from it. |
| Flame3D | `scan4d-flame3d`, after `scan4d-normalize`. `scan4d-convert target=flame3d` runs both. The converter and its contract stay in [tools/scan4d-to-flame3d](../../tools/scan4d-to-flame3d/README.md), and the flow runs a copy. |

## Why

- **One bundle to keep right.** The three exports were three staging paths and about 900 lines
  of Swift (`NerfstudioExport`, `Flame3DExport`). They were rebuilt per format, shipped in app
  releases, and could only be tested on a device.
- **Layouts change faster than the app.** What an engine insists on is tuned against its
  version: depth at the image's size, all-or-none sidecars, one resolution for flame3d. A
  flow changes in minutes; an app export changes in a release.
- **The server does it better.** `scan4d-normalize` already held the per-device still-focal
  correction. Both formats made there get it; the app's exports never had it.
- **No Scan4D consumer depended on its old shape**, so it could grow into the superset.

## What it costs

- **No zip that trains as-is straight from the phone.** A laptop user gets it from the
  server, or runs `scan4d-normalize`'s `normalize.py` on the export.
- **Bigger uploads for 360° captures.** Scan4D keeps the equirect originals, which the
  Nerfstudio export dropped. The server's Nerfstudio zip still leaves them out.
- **Every export colorizes first.** Scan4D now carries the mesh, so an uncolored scan is
  colored before it exports, as the mesh exports always were.

## Compatibility

- **Stored names.** `ExportFormat.persisted` maps "Polycam", "Nerfstudio", "Flame3D" and "RAW"
  to Scan4D. The names live in SwiftData and `@AppStorage`, and a scan or preference holding
  one now exports the bundle that replaced it (`ExportFormatTests`).
- **Server.** `scan4d-normalize` still reads the Nerfstudio exports already uploaded.
  `tools/scan4d-to-flame3d --verify` still checks an old app Flame3D bundle.
- **Upload paths.** Uploads land in `exports/scan4d/`, beside the older `exports/nerfstudio/`
  and `exports/flame3d/`.

## Evidence

Measured 2026-11-09 against exports on the lab workstation; details are in each flow's README.

- **Same dataset as the app's Nerfstudio export.** `scan4d-normalize` on a real 360° Scan4D
  export matches its own path on the app's Nerfstudio export of the same scan, 394 frames.
  The frames, intrinsics, poses, sidecars and masks all match. Depth is identical at the
  LiDAR raster.
- **Same focal correction.** Room `7A49` (109 iPad stills) gets the same correction both ways,
  with bit-identical depth.
- **Old byte-swapped depth.** A scan captured before #93 has byte-swapped depth. It is read the
  right way round: stored values with a median of 32515 mm come out at 0.7–3.5 m.
- **flame3d accepts the bundle.** The bundle `scan4d-convert target=flame3d` made from `7A49`
  passes `--verify`.
- **The focal correction doesn't show on 7A49.** Its mesh-vs-LiDAR check is the same with and
  without it (9.8% vs 9.9% within 2 cm). That room's per-view ARKit pose error dominates.

## Open

- **Delivering the flame3d bundle.** How it reaches flame3d is undecided; the flow only writes
  it.
- **Running flows on upload.** Starting `scan4d-splat` or `scan4d-convert` when an upload
  lands (an event trigger in the stack) is proposed, not built.
