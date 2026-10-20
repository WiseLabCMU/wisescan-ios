# Developer & field-test tools

The debugging surface built up over the 360° arc, in one place. Everything here is
reachable **on device, without a debug session** — that constraint shaped most of it.

## Settings → Developer Mode (master toggle)

Reveals the developer section in Settings and the BLE Probe card on the Dashboard.
The two diagnostics toggles below persist on their own keys, so turning Developer
Mode off does not silently change what a field build records.

### Performance Diagnostics (the big one)
Gates on the **setting, not the build configuration** — it works identically in
Release, which is what the field mostly runs. ON enables:

- **`[perf]` log lines** across the pipeline: `[RigCal]` solve records (scan id, offset,
  yaw, zncc, per-still yaw spread, rails), `[VertexColor]` frame selection + gray
  fraction, `[Colorize]` face generation, `[PerfTimer]` step timings, `[TrackStab]`
  tracking jumps and mesh purges, `[LocDiag]` relocalization/map health, `[Session]`
  interruptions.
- **MainThreadWatchdog** — logs `main-thread stall BEGIN/END (max no-frame gap Nms)`
  for stalls over 400 ms. Mid-recording stalls ≥4 s independently hard-trip the VIO
  guard (that is a capture-safety mechanism, always on).
- **MemDiag** — 1 Hz `footprint/resident/faces/verts/anchors/fps/cpu/thermal` telemetry
  plus lifecycle events (`RECORD-START`, `RP-STOP`, …) and per-thread CPU breakdowns.
- **os_signpost intervals** for the Instruments timeline when a cable IS available.

Decision-bearing lines (map-suspect verdicts, link drops, calibration rails) log at
`.notice` on their own categories regardless of this toggle — they must be explainable
from any bundle.

### Export Diagnostics Log (Settings button)
`DiagnosticsLogExport` reads the unified log for this app and hands back a text file —
the `scan4d-diagnostics-*.txt` files this project's field loop runs on. Two hard limits,
both iOS-imposed: **current launch only** (`OSLogStore` on iOS reads the running
process; for an earlier run, use a sysdiagnose), and **`.info` lines are memory-only**
(anything that must survive to an export is logged `.notice`). The header stamps entry
count, device + iOS version, whether Performance Diagnostics was ON, and — since
47cbbc5 — the **build configuration**, so timings are never mis-attributed again.

Field workflow: scan → Settings → Export Diagnostics Log → share sheet, no computer
involved.

### Simulation toggles
`Simulate IMU & Poses` (synthetic circular trajectory past the overlap gates),
`Simulate Camera Images` (rendered synthetic frames), `Simulate Depth Maps`,
`Simulate Meta Wearable` (MockDeviceKit, no glasses needed). For pipeline testing
away from hardware.

### Color from 360° Faces (A/B probe)
Colors the preview mesh **exclusively** from cube faces cut from the scan's own 360°
stills at their baked poses — a pose-accuracy measurement: misplaced color reads back
pose error directly. Faces carry depth **rasterized from the scan's own mesh**, so
occlusion is ON and the probe measures pose rather than bleed. Privacy fail-closed
applies (maskless face frames skip on privacy-ON scans). Re-run Color after toggling;
compare against the OFF (keyframe) baseline. The gray fraction for each run is in the
diagnostics log.

### Keep 360° Originals on Camera
Debug-only escape from the security sweep that deletes each transferred still from the
camera. Leave OFF except when comparing device bytes against camera-side originals —
the camera's open AP is the weakest place to leave raw equirects.

## Dashboard (Developer Mode)

- **BLE Probe card** (`ThetaBLEProbe`) — the GATT bench that established the whole
  Theta BLE contract: scan/identify/wake/shutter rounds, characteristic property
  dumps. Reach for it when BLE misbehaves in a NEW way; the connect path already logs
  property bitmasks at link-ready for the known failure modes.
- **Camera storage panel** — camera-side file count + confirmed bulk erase.

## Raw capture dump (EXPERIMENT, not gated)

**Location detail → Raw Capture (experiment)**, under the Rescan / Connect buttons. An
ARKit-free capture to test the premise behind a splat-quality focal scan: can the photo
pipeline deliver full-sensor stills back-to-back while LiDAR depth keeps streaming, and can
both be aligned to the IMU by timestamp alone. No pose, no coverage, nothing saved into the
scan store. The capture tab's AR session is paused the moment the screen opens so the
capture session can take the camera (`ScanStore.rawCaptureActive`).

`RawCaptureSession` runs one `AVCaptureSession` on the LiDAR camera: stills from the photo
output at the format's largest photo dimensions with depth delivery requested, one capture
in flight, fired again as soon as the previous one finishes unless the blur gate holds it; an unfiltered
depth stream synchronized with the video stream (video is never saved, it carries the
intrinsics attachment); and every CoreMotion stream (raw gyroscope, raw accelerometer, fused
device motion, magnetometer) as its own file at the sensor's own maximum rate. The requested
interval (`rawCaptureIMUUpdateInterval`) is far below any hardware minimum, so CoreMotion
clamps each stream to the fastest it can deliver; the achieved rate is measured from the
sample timestamps and written to `manifest.json` (`totals.gyro_hz` etc.) rather than
assumed. The on-screen panel shows the negotiated formats and live counters
(saved/requested/failed/gated stills, last latency, exposure, ISO, depth frames
received/dropped/saved, per-stream IMU counts and achieved Hz, interruptions). Stop zips
the directory into `Documents/RawCaptures/raw_capture_<location>_<stamp>.zip` and offers
the share sheet. Knobs are the `rawCapture*` constants (photo quality prioritization,
codec and JPEG quality, responsive capture, depth PNG rate cap, the exposure cap and blur
budget below).

**Sharpness.** The first dump ran with auto exposure uncapped and a fixed gyro threshold; AE
sat at 1/30 s indoors and a good share of the stills were blurred at walking pace. Two
controls now exist, both things ARKit never allowed:

- **Exposure cap** (`rawCaptureMaxExposureSeconds`, default 1/120 s). A ceiling on the
  auto-exposure duration via `activeMaxExposureDuration`: AE keeps metering and raises ISO
  instead of the shutter. Clamped to the format's exposure range; the effective value is in
  `setup.maxExposureCapSeconds` and on screen as `cap`. Where light is too low even at the
  sensor's top ISO the still goes dark rather than blurred, which is the right failure for a
  reconstruction input. 0 disables the cap.
- **Blur budget** (`rawCaptureBlurBudgetPx`, default 2 px). A still is requested only while
  gyro rate x the exposure AE is about to use x focal length (photo pixels) predicts at most
  this much smear. A fixed angular threshold cannot be right across lighting: the AR path's
  0.5 rad/s is a 50 px smear at 1/30 s on a 4032 px frame and 3 px at 1/500 s. The focal
  length starts from the format's field of view and is replaced by the first photo's
  calibration data. The AR path's angular ceiling (`motionBlurAngularVelocity`) stays as a
  backstop for when the exposure reading is unavailable. Rotation only: translational blur
  needs a pose, which this path does not have, so a fast sidestep close to a surface still
  gets through.

The gate's inputs at each request land in `photos.csv` (`request_omega_rad_s`,
`request_exposure_s`, `predicted_smear_px`). The on-screen `ae` / `smear` line turns orange
while the gate is holding, which is the operator's cue to slow down; `gated` counts the
held requests.

**Spacing.** Without it the loop fires the next still the instant the previous one
finishes, so the rate is the photo pipeline's latency and "stills per degree" is whatever
rotation happened during one round trip: dense when moving slowly, sparse when moving fast.
The spacing gate holds the next still until the viewpoint has changed since the previous
one, by either of:

- `rawCaptureStillSpacingRotationDeg` — rotation of the fused attitude since the last still.
- `rawCaptureStillSpacingShiftFraction` — image shift since the last still, as a fraction of
  the frame width, from a block-matched global shift between consecutive luma thumbnails of
  the video stream (`ImageShiftEstimator`, at `rawCaptureFlowHz`). This is how a sidestep
  registers: rotation shows up here too, so the two thresholds should agree (one frame width
  is one horizontal field of view, so 0.12 is about 8 degrees of pan). Featureless frames
  are called still rather than guessed.

`rawCaptureStillMinIntervalSeconds` is a hard floor regardless of motion and
`rawCaptureStillMaxIntervalSeconds` a timeout that also sets what a pause yields: the
unspaced build fired 3 to 5 near-identical stills per pause (one per pipeline round trip);
with the timeout at 1 s a pause yields one still per second, and at 0 exactly one still per
pause, which is the better input for splat training since duplicates add nothing but hand
tremor. Both motion thresholds at 0 restores the unspaced loop. Each still's row in `photos.csv`
carries the inputs and the verdict (`interval_since_prev_s`, `rotation_since_prev_deg`,
`shift_since_prev_frac`, `flow_speed_frac_s`, `spacing_reason`), and the `space` line on
screen shows the accumulation toward each threshold, `held` checks, and the last reason. To
tune, run the analysis tool below on a dump to see the median rotation per still as it is
now, and set the thresholds at the spacing you want.

**Analysing a dump.** [tools/rawcapture-analyze/analyze.py](../tools/rawcapture-analyze/README.md)
reads the zip and prints the still rate, the rotation between consecutive stills, the
rotational smear each still actually had from the gyro against the budget, the same motion
re-evaluated at the old 1/30 s shutter and old fixed gate (to separate what the shorter
shutter did from what the stricter gate did), depth-stream gaps during in-flight stills,
and the achieved IMU rates.

**Clock.** Every `host_ts` is seconds on the host clock (time since boot). Capture
timestamps are converted from the session's synchronization clock; CoreMotion reports on the
host clock natively, so the columns subtract directly. `manifest.json` records wall time and
uptime at start.

Contents of the zip:

| Path | What |
|---|---|
| `manifest.json` | `setup` (device, negotiated video/photo/depth formats, which deliveries the pipeline supported and enabled, knobs) and `totals` |
| `photos/photo_NNNNN.jpg` | Full-sensor processed still. JPEG at `rawCaptureJPEGQuality` by default so every downstream reader opens it; `rawCapturePhotoCodec = .hevc` writes `.heic` instead (smaller, needs libheif in the pipeline). The same ISP processing applies either way; only the container differs. `setup.rawPhotoPixelFormats` in the manifest lists the Bayer RAW formats the device offers (empty = DNG capture unavailable) |
| `photos.csv` | Per still: `host_ts`, request time, latency, dimensions, exposure, ISO, the attached-depth file and dimensions, intrinsics (`fx fy cx cy` + reference dimensions) from the calibration data |
| `photo_depth/photo_NNNNN.png` | 16-bit mm depth delivered **with** that photo. Absent when the pipeline attached none, which is one of the answers this dump exists to give |
| `depth/depth_NNNNNN.png` | 16-bit mm streamed depth, capped at `rawCaptureDepthSaveMaxHz` |
| `depth_frames.csv` | **Every** streamed depth frame: `host_ts`, dropped flags, the synchronized video frame's time, dimensions and intrinsics, and the saved file if any |
| `imu_gyro.csv`, `imu_accel.csv` | Raw gyroscope (rad/s) and accelerometer (g), each at its sensor's maximum rate. These are the streams a motion reconstruction integrates |
| `imu_devicemotion.csv` | Apple's fused estimate beside the raw streams: attitude quaternion, rotation rate, user acceleration, gravity |
| `imu_magnetometer.csv` | Raw, uncalibrated magnetometer (microtesla). Recorded because it is free; noisy indoors |
| `events.log` | Session lifecycle, interruptions, runtime errors, failed writes |

What to read off a dump: the still rate (`photos.csv` row spacing) at each quality
prioritization; whether `photo_depth/` exists at the largest photo dimensions; whether
`depth_frames.csv` keeps its cadence through the moments stills are in flight (the
`request_host_ts`..`host_ts` windows in `photos.csv`); the achieved IMU rate per stream
(`totals.*_hz`, and the row spacing in each IMU file); and the IMU-to-depth timestamp
agreement. A photo's `host_ts` is the capture pipeline's time for the still, and
`exposure_s` beside it bounds where within the exposure the IMU should be sampled. The
actual smear of a still is the integral of the gyro rate over `[host_ts, host_ts +
exposure_s]` from `imu_gyro.csv` times `fx`; comparing that with `predicted_smear_px` (a
single sample at request time) shows how much of the blur the gate could have caught.

## Process-step tools (not gated)

- **Redo 360° Calibration** — long-press the Process action. Forces a fresh photometric
  solve; also the recovery path after correcting the rig-height tape. Solver-version
  bumps re-solve every scan automatically on its next Process (the self-heal mechanism).
- **Calibration provenance in every sidecar** — `rig_calibration_railed`, `_zncc`,
  `_yaw_spread_deg`, `rig_rod_anchor_m`+`_source`, `camera_clock_offset_ms`: the solve
  can be audited from an exported bundle alone. `schemas/equirect_still.schema.json`
  is kept in lockstep with what ships (audited against real bundles).

## Off-device

- **`tools/rigcal-ab/`** — the Mac-side solver harness (ffmpeg + numpy venv): re-run
  the photometric solve against exported `staging_*` bundles, A/B cost functions,
  reproduce any scan's solve offline. Its README carries the edge-vs-photometric
  verdict that led to v15.
- **`tools/scan4d-to-flame3d/`** — converts a Nerfstudio export into a flame3d-core
  input bundle (3D object segmentation + semantic search), with a mesh-vs-LiDAR
  frame check. Its README is the contract the app's Flame3D export follows; `--verify`
  checks an exported bundle before upload.
