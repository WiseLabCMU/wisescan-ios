# 360° Still Source — Flows & Sequence Diagrams (post-pivot)

Companion to [still-source-360.md](still-source-360.md). This documents the flows **as
implemented after the post-process-calibration pivot** (2026-07-31, solver v7). Every
participant name below is a real type; every message is a real call or observable state
change. Cross-cutting invariants these flows must preserve:

- **Privacy fail-closed**: nothing captured leaves the device unverified; raw
  `equirect_stills/` and any face frames derived from them stay inside `raw_data/`
  (commit-blocked by the privacy guard) and only exit via the export privacy passes.
- **Sidecar-derived state**: equirect download/bake state lives ON DISK (sidecar present
  + JPG missing = pending download; `rig_calibration_source` + `..._solver_version`
  stamp = baked). No separate queue store to desync; version bumps self-heal old scans.
- **Poses bake at Process time** from the scan's own stills against the complete mesh;
  capture records only phone pose + timestamps (boot-relative `frame_timestamp` labeled,
  wall-clock `captured_at_epoch_ms`; metric everywhere — CONTRIBUTING → Units & time).
- **Yaw and elevation-offset are per-scan nuisances** (Theta re-derives its stitch
  reference; mounts sag); dy anchors to the user-measured rig height; dLat/pitch solve
  free inside mechanical bounds.

## 1. Overview — major sections

```mermaid
sequenceDiagram
    autonumber
    actor U as Operator
    participant CV as CaptureView
    participant TCM as ThetaCameraManager
    participant PP as ScanPostprocessor
    participant CAL as EquirectPostCalibration
    participant COL as VertexColorAccumulator
    participant EXP as ScanExportManager

    U->>TCM: connect Theta (Dashboard)
    TCM->>TCM: firmware gate · topBottomCorrection(Apply) · disableAutoSleep
    U->>CV: start recording
    loop each stillness pause
        CV->>CV: keyframe (hi-res + depth)
        CV->>TCM: trigger 360° still → sidecar (phone pose, NO cam_transform)
        TCM-->>TCM: download queue drains between triggers
    end
    U->>CV: stop → save scan bundle
    U->>PP: land on Location Detail (auto)
    PP->>TCM: finish pending equirect downloads
    PP->>CAL: calibrate rig from scan stills + mesh.obj
    CAL->>CAL: bake cam_transform + provenance into every sidecar
    PP->>PP: registration · proxy → isProcessed (frees buttons)
    U->>COL: Color (manual)
    COL->>COL: project frames → consensus median → colors.bin → isColored
    U->>EXP: Save / Upload
    EXP->>EXP: privacy passes → stage equirects → cut cube faces (baked poses) → zip
```

## 2. Detailed flows

### 2.1 Startup / start capture

```mermaid
sequenceDiagram
    autonumber
    actor U as Operator
    participant DB as Dashboard (ThetaCameraCard)
    participant TCM as ThetaCameraManager
    participant X as Theta X (OSC)
    participant CV as CaptureView

    U->>DB: Connect
    DB->>TCM: refreshConnection()
    TCM->>X: /osc/info (model, firmware, serial)
    alt firmware below minimum
        TCM-->>DB: state=.failed("Firmware too old") — connection BLOCKED
    end
    TCM->>X: setOptions _topBottomCorrection=Apply (BLOCKING — leveling invariant)
    TCM->>X: setOptions sleepDelay=65535 (non-fatal — stills persist on camera until downloaded)
    TCM->>X: fileFormat + fileFormatSupport (resolution picker)
    U->>CV: Capture tab
    CV-->>U: 360° chip — model+serial · rig height (orange "unset — Settings" until measured) · sufficiency (while recording)
    U->>CV: Record
    CV->>TCM: beginScanStillSession(rawDataDir) — seq counter seeded FROM DISK
    Note over CV: first still on an unmeasured rig also fires a one-time toast
```

### 2.2 AR/VR capture (per stillness pause)

```mermaid
sequenceDiagram
    autonumber
    actor U as Operator
    participant FCS as FrameCaptureSession
    participant CV as CaptureView
    participant TCM as ThetaCameraManager
    participant X as Theta X
    participant D as raw_data/equirect_stills

    U->>FCS: pause (device settles)
    FCS-->>U: stillness chime (cue 1)
    U->>FCS: shutter tap → requestStillCapture() arms
    FCS->>FCS: keyframe fires while stillness holds (hi-res + LiDAR depth + mask)
    FCS-->>U: shutter click (cue 2)
    CV->>TCM: captureStillForScan(phonePose, frameTimestamp, samplePose)
    Note over TCM: epoch-ms stamped at entry — motion probe samples pose each 250 ms
    TCM->>X: triggerStill()
    CV-->>U: chip: "📸 exposing — hold still…" (orange)
    X-->>TCM: file listed (exposure + stitch done)
    TCM->>D: still_NNNN.json — phone_transform, frame_timestamp, captured_at_epoch_ms, trigger_motion_m/deg, camera_file_url — NO cam_transform
    TCM-->>U: done tone + success haptic (cue 3 — walk now)
    TCM->>TCM: enqueue JPG download
    loop while NOT capturing (yields to triggers)
        TCM->>X: download next queued equirect → still_NNNN.JPG
    end
    CV-->>U: chip: N stills · spread X.X m · ↓pending
```

### 2.3 Stop / save

```mermaid
sequenceDiagram
    autonumber
    actor U as Operator
    participant CV as CaptureView(+Recording)
    participant TCM as ThetaCameraManager
    participant FS as Scan bundle (disk)

    U->>CV: Stop
    CV->>FS: mesh.obj · transforms.json · worldmap · roomdata sidecar
    Note over TCM: in-flight still crossing Stop: LOUD DROP if rawDataDir moved (stop-race guard)
    CV->>FS: scan record persisted (SwiftData)
    Note over TCM,FS: undownloaded JPGs remain ON CAMERA — state derivable from disk (sidecar w/o JPG) — Process finishes them
    CV->>CV: deferred RoomBuilder continues post-save (roomplan.json when ready)
```

### 2.4 Auto post-process (on landing at Location Detail)

```mermaid
sequenceDiagram
    autonumber
    participant LDV as LocationDetailView
    participant PP as ScanPostprocessor
    participant TCM as ThetaCameraManager
    participant CAL as EquirectPostCalibration
    participant SOL as RigCalibrationSolver
    participant D as scan bundle

    LDV->>LDV: onAppear → autoProcessPending()
    LDV->>PP: enqueue scans where pendingSteps ≠ [] (FIFO, background — colorize EXCLUDED)
    PP->>D: pendingSteps: downloads? calibration (stamp missing OR solver_version < current)? registration? proxy?
    opt equirectDownloads
        PP->>TCM: download missing JPGs (camera gone → card "needs the 360° camera" — queue persists)
        Note over TCM: camera.delete after verified download (security plan)
    end
    opt equirectCalibration
        CAL->>D: loadStills (sidecars + JPGs) · parse mesh.obj
        CAL->>CAL: selectBySpread(≤5) · ONE-pass mesh-edge extract · per-still edge maps
        CAL->>SOL: solve — coarse yaw circle (24, stride 3) → elevation sweep (±16 rows) → NM ≤2 lobes
        Note over SOL: dy anchored to measured rig height ±0.05 (else mech envelope ±0.3), dLat/pitch free, v7 unmirrored frame
        SOL-->>CAL: dy dLat yaw pitch elev + residual
        CAL->>D: bake cam_transform + rig_calibration_source + solver_version + elevation_offset_deg into EVERY sidecar
        CAL->>CAL: persist rolling profile (sanity-gated) · diagnostics PNGs
        Note over CAL: less-than-3 stills → yaw-only w/ persisted geometry, failure → prior stamp (scan never lost, provenance honest)
    end
    PP->>D: registration · proxy
    PP-->>LDV: per-step phase pill → isProcessed=true (frees rescan/link/save/upload/color)
    Note over LDV: manual "Redo Processing" stays in the menu (camera-gone recovery, future upgrades)
```

### 2.5 Colorize (manual)

```mermaid
sequenceDiagram
    autonumber
    actor U as Operator
    participant LDV as LocationDetailView
    participant PP as ScanPostprocessor
    participant COL as VertexColorAccumulator
    participant D as raw_data

    U->>LDV: Color (enabled once isProcessed)
    LDV->>PP: run(steps: [.colorize])
    PP->>COL: colorizeFromSavedFrames(rawDir)
    alt Dev switch "Color from 360° faces" OFF (default)
        COL->>D: cameras/*.json + images/ (keyframes ×3 weight, motion ×1, per-frame LiDAR depth occlusion + person masks)
    else Switch ON (cube-face accuracy probe)
        COL->>D: (re)generate face_frames/{cameras,images} from equirect_stills + BAKED poses (EquirectFaceExport)
        COL->>D: color from face frames ONLY (is_keyframe=true, NO depth ⇒ no occlusion — expect bleed, that is the point — color placement reads back cube-face pose quality)
    end
    COL->>COL: project per frame (GPU w/ CPU fallback) → top-K accumulate → consensus median
    COL->>D: colors.bin → isColored=true
    Note over COL,D: face_frames/ lives INSIDE raw_data (unblurred) — never staged for export
```

### 2.6 Export / save / upload

```mermaid
sequenceDiagram
    autonumber
    actor U as Operator
    participant LDV as Scan card / LocationDetailView
    participant EXP as ScanExportManager
    participant FACE as EquirectFaceExport
    participant Z as staging → zip

    U->>LDV: Save / Upload (gated on isProcessed)
    LDV->>EXP: prepareExport(scanDir, format, phase:)
    EXP->>Z: stagePolycamPayload (mesh, cameras, images, depth, masks)
    EXP->>Z: privacy passes — masks → pixelate person regions, FAIL CLOSED (unverifiable frames excluded)
    EXP->>Z: stageEquirectStills — per-still privacy (filter ON ⇒ blur-or-exclude, OFF ⇒ consent logged, privacy_filter=false in metadata)
    EXP->>FACE: emitCubeFaces — poses from SIDECAR cam_transform ONLY (capture-provenance, v7 convention shared with the solver)
    FACE->>Z: 5 faces/still + Polycam camera JSONs (camera_pose_source, still_source, elevation_offset_deg available for sampling compensation — not yet applied)
    EXP->>Z: zip with phase labels (Privacy blur i/n → Cube faces i/n → Zipping…)
    LDV-->>U: card pill shows phase + meter — upload posts to the configured server
```

## Diagram maintenance

These diagrams are hand-drawn against the code as of solver v7. When a flow changes,
update the diagram in the same PR — the review checklist item is "does the mermaid still
tell the truth?". Names in diagrams are grep-able anchors on purpose.
