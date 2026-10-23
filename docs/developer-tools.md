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

## AR still capture dump (EXPERIMENT, not gated)

**Location detail → AR Capture**, under the Rescan / Connect buttons. It is the **Rescan flow up to Start**:
the same entry (`startRescan`, so the same world map, post-process gate and suspect-map
confirm), relocalization, ghost, alignment and manual nudge. Only Start and Stop differ
(`ScanStore.activeScanKind == .focus`, `CaptureView+StillCapture`). The goal is high-quality stills
and nothing else: no stream images are saved.

**Start** goes through the same pre-start gates as a rescan's record tap (tracking out of
cold init; with Perf Diagnostics, the short hold for the ICP correction), computes the same
manual-nudge bake as `startRecording`, and raises `isStillCapturing`. On that edge
`ARCoverageView.beginStillCapture` does what record-start does **to the frame**, in the same
order: re-run without resetting tracking (the loaded map keeps the relocalized frame), the
dev ICP bake, then the manual-nudge bake. It differs in **content**: LiDAR scene depth only,
no mesh reconstruction, plane detection or RoomPlan, and the ghost leaves the scene. Only then
does the engine accept frames, so no still carries a pre-bake pose.

**Coordinate space.** Poses are in the world-map scan's raw capture frame with the rescan's
record-start bakes applied, i.e. exactly where a rescan recorded from the same alignment
would put them. A rescan then registers its own RoomPlan to the original scan at save; this
mode has no RoomPlan, so instead the dump carries the world-map scan's
`registration.json` (`world_map_registration.json`: that raw frame to the original scan's
canonical frame). `setup.icpBake` and `setup.manualNudgeBake` record what was baked.

**Stills** come from `captureHighResolutionFrame`, one in flight. Each returns its own
ARFrame: pose, intrinsics and exposure of that instant, plus the 256x192 LiDAR depth and
confidence. The resolution is the capture view's high-resolution 4:3 format's still (full
sensor: 4032x3024 on an M1 iPad Pro). ARKit hands the image over unencoded; the app encodes
JPEG on its own queue, with the still's exposure time and ISO in its EXIF, and holds new
stills while `arStillMaxPendingEncodes` are queued.

**Gates**, evaluated on every tracked frame (`ARStillCaptureGates`, unit tested):
- *Blur:* predicted **image motion**, pose only. The camera's velocity and angular velocity
  come from two ARKit poses `arStillVelocityWindowSeconds` apart, enter as vectors, and are
  applied to the frame's centre and four corner points at the near-scene depth (the
  `arStillGateDepthPercentile` of confident LiDAR samples); the largest image velocity times the
  exposure is held to `arStillBlurBudgetRad` (0.9 mrad, 3 px at the 12MP still's 3,346 px
  focal). The budget is an **angle**, so a 48MP still is held to the same real sharpness (6 px)
  rather than silently twice as strict; it still covers sidesteps (a sideways move at v m/s, Z m
  from the scene, sweeps v/Z rad/s). Rotation and sideways motion cancel where they really do:
  orbiting the focal area while keeping it centred barely moves it in the image. The first
  capture used a 2 px budget on rotation + sideways speed as magnitudes, which cannot cancel;
  replaying that capture's motion, it fired every 2.05 s, this rule every 1.37 s, and the first
  capture's sharp stills had moved up to 2.8 px (p90) during their exposure.
  That pose term averages rotation over 0.1 s, which smooths hand shake out, while a 2 ms
  exposure sees the shake at its peak. So the gate also takes the gyro's **peak rate** over the
  last `arStillGyroPeakWindowSeconds` (50 ms) times the exposure, and holds the still if either
  term is over budget. Replaying the iPhone office capture (all at 1/500): of the stills the
  pose term passed, 30% turned faster than the budget allows at their actual capture instant;
  requiring a 30 ms gyro peak to pass too left 21%, 50 ms 7%, 100 ms 6% (while holding more
  frames). In `photos.csv`, `predicted_image_motion_smear_rad` is the gate's value, the larger
  term (`_px` is the same in still pixels); `pose_smear_rad` and `gate_gyro_smear_rad` (from
  `gate_gyro_peak_rad_s`) are the two terms. The rotation and translation columns are the old
  sum's parts, kept for comparison.
- *Check at capture:* a still is not exposed at the instant the gate requests it (in the iPhone
  capture half the stills were timestamped before the request, the rest up to 0.55 s after). Each still's own timestamp is looked up in the gyro history: `capture_gyro_rad_s` (the
  rate there), `capture_gyro_smear_rad` (times the still's exposure, rotation only) and
  `capture_over_budget`; empty when the gyro history did not cover that instant. Logged only:
  an over-budget still is kept and still counts toward spacing.
  `totals.stills_over_budget_at_capture` counts them; the panel shows the last still's figure.
- *Spacing:* a still once the view has turned `arStillViewpointThresholdDeg`, or a sideways
  move subtends that angle at the near scene (parallax), or `arStillMaxIntervalSeconds`
  has passed.
- *Exposure:* `arStillMaxExposureSeconds` (1/120) is applied to ARKit's own camera through
  `configurableCaptureDeviceForPrimaryCamera` as the longest exposure auto exposure may use. In
  the first capture 93 of 94 stills sat exactly at it: iOS holds the longest allowed exposure and
  only shortens it once ISO bottoms out.

**The session stays put during a capture.** The world map only initializes the pose; once a
capture starts, nothing reloads it. The first iPhone capture lost scene depth for good 107 s in
because something re-ran the session mid-capture (tracking went normal -> initializing ->
relocalizing, i.e. a map reload with a tracking reset) using the app's normal configuration,
which does not request depth. A reload like that also discards the record-start frame bakes.
AR Capture never sets `isRecording`, so the pre-record rescan paths had stayed live. Now the
pre-record safeguards read one state, `CaptureView.isCapturing` (recording or capturing stills):
the relocalization watchdog and its Try Again stand down, Re-relocalize is a no-op, the Ghost
Mesh chip is hidden during a focus scan, ARCoverageView's ghost-reload path is skipped, and
leaving the capture screen stops the capture. Every `session.run` in ARCoverageView goes
through `Coordinator.runSession`, which puts the active `SessionRole`'s frame semantics back
on any configuration built without them (logged as `[Session] ... re-added`). The exposure
cap lives in `CaptureExposurePolicy`, which re-applies it if a re-run reset it on the device.
The engine is the safety net for anything else: it logs every tracking-state change and every
depth loss or recovery to `events.log`, re-requests scene depth on the live configuration (no
tracking reset) if a re-run dropped it, and logs once if depth is requested but ARKit simply
stopped delivering it, with the thermal state. Through a dropout the gates hold the last good
near depth for `arStillDepthHoldSeconds` (10 s), so sidesteps and parallax still count.
Pose drift after initialization is accepted: the poses are a prior for the image-based pose
solve, not ground truth.

**Short exposure** (the yellow SHORT EXP switch on the trailing edge, mid-height; on by default,
usable before Start and during a capture, and kept across captures in a session). With it on,
the exposure cap follows the light instead of sitting at 1/120: every
`arStillShortExposureUpdateSeconds` the cap becomes exposure x ISO / `arStillShortExposureISOCeiling`
(ISO 800), corrected by auto exposure's own target offset and clamped between
`arStillShortExposureFloorSeconds` (1/500) and 1/120 (`ARStillCaptureGates.shortExposureCap`,
unit tested). Auto exposure keeps running and raises ISO to match. The blur gate needs no change:
it reads each frame's real exposure, so a shorter exposure loosens it in proportion. Replaying
the first capture's light, ISO 800 would have meant a median exposure of 1/611 s, held at the
1/500 floor. Each still records `short_exposure` and the cap in force (`exposure_cap_s`), so one
capture can mix both settings; `totals.stills_short_exposure` counts them.

Why it is on by default: in the iPhone 17 Pro Max office capture (all 202 stills at about 1/500,
ISO median 229) the stills came out blur-free at about 2.4 times the rate of the 1/120 iPad
captures (1.06 against 0.44 stills/s). The gate turns a shorter exposure into faster movement,
not sharper stills. No flicker banding showed. The cost is texture: the ISP denoises, so noise
stays flat (1 to 1.6 grey levels at any ISO) while fine texture at 1 to 2 px, compared on the
same 3D point across stills, comes out 14% weaker at 2.5 to 4 times the ISO and 24% weaker
beyond that. The pose solve showed no trend with ISO. Still untested: a room lit only by LEDs.
1/120 s integrates exactly one cycle of the 120 Hz flicker of mains-powered LED and fluorescent
light (60 Hz countries); shorter exposures can show rolling-shutter bands and frame-to-frame
brightness pulses there (that office had a lot of daylight). Switch it off if stills band.

**Debug panel** (mid-screen while AR Capture is active). Its large first line is the point of
the experiment: the last still's resolution, exposure and ISO; the next line is the stream's
size and exposure against the cap. Below: still counts and rate, latency, why the last still
fired, frames held by each gate, the gate inputs, the last still's blur at capture, the
per-frame work timing, and the exposure-cap note.

**Per-frame work timing.** ARKit hands frames to the capture view's delegate on its own serial
queue; a handler that runs long holds frames back, and a starved session can degrade tracking.
While capturing, the app times the whole delegate handler and the capture engine's share of it
(`offer`), each frame. The panel shows mean and max; at Stop `events.log` and the manifest's
`frame_work_ms` give frames, mean, p99 and max for both. For scale: the iPhone office capture's
stream ran at 30 Hz (33 ms a frame) with no gap between frames across its 202 stills.

| Path | What |
|---|---|
| `manifest.json` | `setup` (device, stream format, world-map scan and id, original scan id, bakes, exposure cap requested / applied / note, gate settings, `deviceSupportedPhotoDimensions` vs `arkitDefaultPhotoDimensions`, frame and pose conventions), `totals`, and `frame_work_ms` (per-frame delegate work: frames, mean, p99, max) |
| `photos/photo_NNNNN.jpg` | Full-resolution ARKit still, sensor (landscape) orientation |
| `photos.csv` | Per still: `host_ts`, request time, latency, size, exposure, ISO, tracking, depth and confidence files, intrinsics, `c2w_00..c2w_23` pose, and what the gates measured (gyro, sideways speed, near depth, stream exposure, predicted rotation and translation smear, interval, turn, parallax, reason), the angular prediction, `short_exposure` and `exposure_cap_s`, and `gate_depth_held` (1 = a held depth from before a dropout) and `thermal_state`, the blur gate's two terms (`pose_smear_rad`, `gate_gyro_peak_rad_s`, `gate_gyro_smear_rad`), and the check at capture (`capture_gyro_rad_s`, `capture_gyro_smear_rad`, `capture_over_budget`) |
| `photo_depth/photo_NNNNN.png` | 16-bit mm LiDAR depth of the same ARFrame, 256x192, unsmoothed |
| `photo_confidence/photo_NNNNN.png` | 8-bit ARKit confidence of the same ARFrame: 0 low, 1 medium, 2 high |
| `frames.csv` | Text-only pose log of every tracking frame while capturing (the trajectory between stills); no stream images |
| `imu_gyro.csv`, `imu_accel.csv` | Raw gyroscope (also the blur gate's rotation input) and accelerometer |
| `world_map_registration.json` | Copy of the world-map scan's `registration.json`, when it has one |
| `events.log` | Capture lifecycle, exposure-cap changes, tracking-state changes, scene-depth loss and recovery, thermal-state changes, per-frame work timing at Stop, failures |

**Pose convention:** `c2w_*` is ARKit's camera-to-world transform, row-major 3x4; the camera
looks down its -Z axis with +Y up in the image, world +Y is up (gravity), metres. Images,
depth and intrinsics are in the sensor's landscape orientation. All timestamps are seconds
since boot (`ARFrame.timestamp` and CoreMotion share that clock).

**The still's intrinsics are NOT what ARKit reports.** ARKit gives each high-resolution still
the video's intrinsics scaled to the still size, but the still has a narrower field of view.
On the first AR capture (M1 iPad Pro) a multi-view focal refit with every pose held fixed put
the still focal at **1.0476x** the reported value (10th-90th percentile 1.0455-1.0497; principal
point within ~5 px), which matches the photo pipeline's own calibration on the same iPad
(1.0486x). With the reported focal, COLMAP found 18k points with 8% of tracks spanning 3+
stills; with the corrected focal, 61k and 36%, and LichtFeld anchored 70 of 82 cameras' depth
instead of 59. So:
- `fx..cy` in `photos.csv` are right for the **LiDAR maps** (they follow the video geometry) and
  wrong for the **still**: multiply `fx`/`fy` by the still focal scale.
- Depth must be **resampled** into the still's pixel grid (still pixel -> ray with the still
  focal -> video pixel -> depth pixel), not stretched to the still size: the still is the central
  ~95% of the LiDAR map, and stretching misplaces depth by up to ~5% toward the edges.
- The manifest records `videoFieldOfViewDeg`, `distortionCorrectedFieldOfViewDeg` and
  `expectedStillFocalScale` (their tangent ratio), on the hypothesis that the photo path's
  geometric distortion correction is the crop. If that matches the refit on device, the scale
  comes from the manifest and the refit becomes a check.

A smaller open item from the same capture: LiDAR depth reads farther than depth triangulated
from the stills by a roughly constant 0.035 m^-1 in inverse depth (1 cm at 0.6 m, 12 cm at
1.9 m). It is not the intrinsics (flat across the image) and not pose timing (per-still pose
refits are ~1.6 px and uncorrelated with motion). LichtFeld's `ssi-depth` fits scale and
shift per camera, which absorbs most of it; a tape measure on a known object would say which
side is right.

**For the splat pipeline**, the poses give metric scale, gravity and the room's frame, and a
splat trains on them directly. They are not pixel-exact, though: on the first capture a full
SfM pose solve seeded from them moved the stills by about 21 px median and trained 2.7 dB
better on held-out stills, so solve poses from the images and keep ARKit's for scale and
frame. Two gotchas from the
earlier desk-scale runs carry over: LichtFeld normalises 16-bit depth PNGs and rejects desk-scale
millimetre depth as flat (write 0.1 mm units), and its depth anchoring needs a seed cloud.

**Open questions one device run answers:** the still resolution and exposure actually
delivered (first panel line; `photos.csv`); whether the still's exposure honours the cap;
the sustained still rate with the mesh off; whether tracking holds at 1/120 s; and on a 48MP
iPhone, whether ARKit stills stay at 12MP (`deviceSupportedPhotoDimensions` vs
`arkitDefaultPhotoDimensions` and the stills' actual size).

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
