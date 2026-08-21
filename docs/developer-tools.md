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
