# Scan4D

Scan4D is the time-series reality capture application for the WiSEScan platform. It acts as an advanced sensor client designed to bridge high-fidelity device data with backend reconstruction servers.

**Requires:** iOS 18.0+ · ARKit-capable iPhone or iPad · Xcode 26.6+ (CI builds on 26.6; Xcode 27 builds too)  
**Recommended:** LiDAR-equipped device (iPhone/iPad Pro) for full mesh + depth capture  
**Optional:** rig-mounted Ricoh Theta X or Z1 as a 360° still source (BLE wake and shutter plus Wi-Fi transfer on both)

**Backend Integration:** the lab's control plane (`scan4d-server`, private) registers devices, keeps the inventory of spaces, maps, scans and links, takes each synced scan whole as one bundle and unpacks it in its working directory, and asks devices for focus scans (REQ-038). Processing runs in the same stack as Prefect flows from `scan4d-flows` (private): `scan4d-splat` takes a room scan or a focus-scan dump through SfM poses, priors, region masks and LichtFeld training to a Gaussian splat, and `scan4d-convert` makes Nerfstudio and flame3d datasets from a scan. See [Backend Receivers](#backend-receivers).

## Device Support

| Capability | Full Mode (LiDAR) | Lite Mode (No LiDAR) | Proxy Mode |
| :--- | :--- | :--- | :--- |
| **Devices** | iPhone Pro, iPad Pro | iPhone 16, older iPhones/iPads | Meta Ray-Ban, Glasses |
| **RGB Frames** | Yes | Yes | Yes: Streamed via Bluetooth |
| **Camera Poses** | Yes: ARKit tracking | Yes: ARKit tracking | No |
| **Depth Maps** | Yes: LiDAR depth | No | No |
| **Real-time Mesh** | Yes: Scene reconstruction | No | No |
| **Coverage Overlay** | Yes: Wireframe | No | No |
| **Privacy Markers** | Yes: 3D body-center anchors | No (2D blur only) | No |
| **Mesh Preview** | Yes: Colored 3D model | No | No |
| **Server Reconstruction** | `scan4d-splat` flow (SfM poses, LiDAR priors, splat) | Planned: photogrammetry from images and poses (Lite Mode is a test harness today) | Planned: photogrammetry from images alone (proxy mode is a test harness today) |

### Hi-Res Still Keyframe Resolution

When the device is held still, the app requests a native-resolution still via `ARSession.captureHighResolutionFrame` (iOS 16+). **The still's resolution is determined by the active video format's camera configuration**, not by the device alone: standard (non-hiRes) video formats deliver a modestly upscaled sensor readout, while formats flagged `isRecommendedForHighResolutionFrameCapturing` bind the full photo sensor. hiRes **16:9** video formats break Recon3D mesh integration on iPads (zero mesh geometry), but the 4:3 hiRes formats (`1920×1440 @ 30fps [hiRes]`) are mesh-safe — **the app defaults to the highest 4:3 hiRes 30fps format**, falling back to the best standard 4:3 format when none exists. The Developer Mode video-format picker can force any format for per-device testing.

| Device class | Standard 4:3 format | 4:3 [hiRes] format (default) |
| :--- | :--- | :--- |
| iPad Pro M2/M4 | 2016×1512 (verified on-device) | **4032×3024 — verified on-device, mesh intact** |
| iPad Pro A12Z (2020) | untested | **4032×3024 — verified on-device (auto-selected), mesh intact**; 16:9 1080p [hiRes] also verified (4224×2376, narrower FOV) |
| iPhone Pro (13 Pro and later) | untested | 4032×3024 expected (per Apple's ARKit 6 guidance) — untested |
| Non-Pro / no LiDAR | n/a (Lite Mode — stream frames only) | n/a |

Scope of the 16:9 mesh breakage: the zero-mesh failure has only been reproduced with the
**3840×2160 hiRes formats on M-series iPads**. On the A12Z iPad (which offers no 4K
formats), the 16:9 `1920×1080 @ 30fps [hiRes]` format ran with mesh fully intact — so
the auto-selection's 4:3 preference is a conservative choice, not a hard requirement,
and mixed-aspect captures are fine downstream because every frame exports per-frame
intrinsics/resolution.

To check a device: the `[ARConfig]` launch log lists every supported format with its `[hiRes]` flag and the `◀ SELECTED` marker, and each captured keyframe logs `[FrameCapture] Hi-res keyframe captured: W×H`. Please update this table as devices are verified.

## Features

- **AR + VR Capture Modes:** AR mode uses camera passthrough with live wireframe mesh overlay; VR mode renders a live depth point cloud on a black background using Metal shaders. Toggle between modes in Settings.
- **LiDAR Mesh Capture:** Real-time scene reconstruction with live wireframe overlay, capacity HUD, and real-time scan coaching (LiDAR devices only).
- **Scan Coaching:** A unified 4-tier coaching system (`ScanCoach`) provides real-time scanning tips during capture — tracking/capacity warnings always show; pattern-based guidance and progress encouragement can be toggled in Settings.
- **Space Staging Analyzer:** Optional pre-scan analysis phase that checks room conditions before recording a new space (it is not offered during a rescan, a connect or a focus scan). Tap "Analyze" to start a 360° sweep — the app measures ambient lighting, detects doors/screens via RoomPlan, and checks for people in the scene. A report modal summarizes findings with actionable tips (privacy-filter-aware people messaging).
- **Lite Mode:** Non-LiDAR devices capture images + camera poses for server-side photogrammetry. A persistent banner indicates lite mode. *(Note: Lite mode is only available in local debug builds for testing. TestFlight and App Store releases strictly require LiDAR-equipped devices.)*
- **Scan4D (Rescan & Link Adjacent):** Group scans by Location and set the workflow intent when saving. The two intents capture different dimensions of a space: **Rescan Space** is *temporal* — re-capture the same physical area at a later time so the backend can diff or merge versions; **Link Adjacent Space** is *spatial* — capture a neighboring area and stitch the chunks into one larger model. Both relocalize against the previous scan's `ARWorldMap` and show a configurable ghost-mesh overlay (default: magenta) of that prior capture. Adjacent chunks join at a shared boundary anchor: drop one mid-scan with **Pin & Extend**, or relocalize back to it in a later session through a guided alignment overlay.
- **Post-Scan Processing & Plane Registration:** The save path persists raw artifacts only; the room layout (RoomPlan) builds automatically seconds after save, and everything else derived finishes via an explicit **Process** step (per-card button or bulk "Process All" with per-tile progress): **plane registration** aligns each rescan into its location's **canonical coordinate frame** (gravity-locked 4-DOF wall/floor matching with an observability gate, so unobservable solves are refused rather than guessed), and a lightweight **ghost proxy** is generated for future rescan overlays. Post-processing also runs automatically after save and when landing on a location, so the explicit button is mostly recovery. **Coloring is its own verb**: the scan card's primary **Color** button (and bulk Color in both list toolbars, on stitch-graph clusters, and in the combined render) finishes any pending structural steps, then applies camera-based vertex coloring — Metal GPU projection with per-frame LiDAR depth occlusion and a consensus-median reduce; 360° scans can optionally color from cube faces as a pose-quality probe. A trusted registration is baked transactionally (mesh + room layout + `registration.json` sidecar move together, with rollback on failure) and bundled in exports. Share, rescan, and connect are **gated until processing completes** (a scan's sync bundle waits for it too), and a bad-scan check warns right after save when a capture produced no usable room data (so you can redo it while still in the room). During a rescan, the live ghost auto-seats against detected planes.
- **Derived Levels & Ramps (Multi-Level Spaces):** RoomPlan models one floor per room, so a step, a landing, a mezzanine, or a shallow ramp comes back as bare mesh with no plane to represent it. At Process time the ghost-proxy build re-reads the scan's *own* classified mesh (`mesh.obj` + the per-face class sidecar) and recovers those walkable surfaces as oriented planes, written to a `derived_surfaces.json` sidecar and drawn in the mesh preview's semantic overlay. Their categories are deliberately `level` and `ramp` rather than `floor`, so nothing can feed them into a coordinate solve by accident. Wall quads are now **cell-backed**: a RoomPlan quad draws and subtracts mesh only where the classified mesh actually backs it, cell by cell — and a quad that explains less than half the geometry inside its own footprint is **demoted**, neither baking nor subtracting, so a curved or bowed wall keeps its real mesh instead of being flattened to a chord. The sidecar is an on-device artifact; it is not part of any export bundle.
- **Linked-Scan Graph & Combined Mesh:** Each boundary link is recorded in a per-location `stitching.json` manifest (paired anchor transforms + compass headings) and bundled in every Scan4D export. The Scans tab visualizes chained scans as a node graph and can render all linked scans together in one combined-mesh viewer.
- **Privacy Filtering:** A live red-eye indicator marks detected people on-screen, and person regions are pixelated in exported frames and zeroed out of depth maps. All three are driven by ARKit's person-segmentation stencil (no per-frame Vision pass); one body-center 3D anchor per person is unprojected from depth for red privacy markers on mesh previews.
- **Focus Scan (Partial Scan of One Region):** Rescan Space can capture one region instead of the whole room: draw a box on the previous scan's mesh (tap a table to take its box, or tap the surface), pick a detail level — **Check** (about 5 photos, finishes by itself), **Detail** (about 30) or **Splat** (150+, for reconstruction) — and walk around it after the usual relocalization. 12MP stills fire only while the box is in view, under an image-motion blur gate and a short-exposure cap, and a dial shows the directions covered. The result is a partial scan in the same location (photos, poses, LiDAR depth, the box), exported as one zip with people blurred (fail-closed). A region can also be handed to the app by deep link or file, e.g. from a VLM. See REQ-035/037 in [REQUIREMENTS.md](REQUIREMENTS.md) and [docs/design/capture-modes.md](docs/design/capture-modes.md).
- **Automatic Room Photos:** A room scan takes its 12MP photos by itself — whenever the device is steady enough for the (capped, short) exposure and the view has changed by about 15° — instead of saving blurred video frames or waiting for a tap; it backs off when the session is under load. See REQ-036.
- **Capture Quality (Hi-Res Stillness Keyframes):** The app captures native-resolution still photos (`ARSession.captureHighResolutionFrame`, up to ~12MP) as sharp keyframes — automatically in a room scan (above); with a 360° rig, a tap while still pairs a phone still with the 360° still. The AR stream stays on a mesh-friendly format. In AR mode, the coverage overlay shows three states: green (unscanned), amber (depth captured, no photo), and clear camera feed (photo-grade). Photo coverage is tracked on a world-space voxel grid stamped from each keyframe's depth map (so surfaces behind walls are never falsely marked), and the coach nudges you to pause on the amber areas when photo coverage falls behind the mesh. Keyframes are flagged in exports (`is_keyframe`) and weighted higher during vertex coloring; `scan4d_metadata.json` records a `photo_coverage` fraction so backends can triage datasets.
- **360° Still Source (Ricoh Theta):** A rig-mounted Theta captures a full-sphere still at every stillness keyframe, giving reconstruction all-direction imagery the phone's frustum can't see. Connect is BLE-first: pick the camera from a named Bluetooth list, one-time passkey bond, wake-from-sleep over BLE, then an automatic Wi-Fi join; the shutter rides BLE when the link is up (the new file's URL arrives as a push — no polling). Camera poses are solved **per scan at Process time** against the completed mesh (yaw and mount sag are per-scan nuisances; the measured rig height anchors the solve) and baked into each still's sidecar with provenance. A multi-camera roster switches bodies per collection. Camera-side originals are deleted after verified transfer — raw equirects capture bystanders in every direction — and stills leave the device only through the export privacy passes. See REQ-033 in [REQUIREMENTS.md](REQUIREMENTS.md).
- **Scan Capacity Metrics:** Live polygon count, anchor count, drift tracking, and session duration with a composite capacity indicator that warns users when approaching ARKit session limits.
- **Developer Mode:** Toggleable debugging tools — synthetic IMU/camera/depth injection for Simulator testing, performance diagnostics, and a **Force Rebuild Artifacts** switch that re-runs the derived-artifact build (ghost proxy, dynamic mesh, derived surfaces) on an already-current scan so its build diagnostics can be re-read — with a persistent banner across all views. It also holds the capture tuning that used to sit in everyday Settings (image overlap, blur rejection, Semantic Labeling, wireframe colours, Meta glasses frame rate), the 360° camera bench (still resolution, Test Shutter, Download & Preview) and the 3D preview's motion-frame markers. **Restore Default Developer Options** at the bottom puts every developer option back to its default (as turning Developer Mode off does).
- **Sweep Coverage:** A room scan records where the LiDAR sweep actually looked, as per-cell free, surface and visit counts in the raw capture frame, and ships it as `sweep_coverage.bin` in every Scan4D export (a Developer Mode readout shows the live counters).
- **Feature Point Cloud:** Every save serializes ARKit's sparse feature cloud to `arkit_features.bin` (a 128-byte header over packed id and xyz records) in place of the opaque world map, which only ARKit could read. Feature ids survive map save and load, so clouds from successive scans of one location join on id for change detection. Process backfills the file for scans saved before it existed.
- **Share:** Hand a scan to another app or device (Files, AirDrop, Mail) as a Scan4D bundle or a native mesh file (OBJ, PLY, USDZ), picked from Share's menu each time (no stored format setting). The capture data is governed by motion-blur rejection and overlap metrics. The screen stays on while a scan is converted.
- **Control Plane Sync:** Set the lab's control plane server in Settings and the phone keeps it up to date with everything in the spaces you sync (Sync to Lab Server in a space, or Sync on a stitched map in the graph view; Settings → Auto sync adds every space, the ones started after joining (the default), or none). Two parts, as in [docs/design/sync-bundle.md](docs/design/sync-bundle.md):
- **the map**, every sync: base and tip scans, scans, stitch links, registrations, focus regions, and each room scan's RoomPlan layout as a preview;
- **each scan's bundle**, once processed: everything it holds as one zip (the Scan4D export plus the relocalization map and the proxy meshes), built through the export's privacy passes, uploaded in a background session (it finishes with the screen locked) over Wi-Fi only unless the user allows cellular, and chosen in a pending checklist (selected by default, except a scan captured with the Privacy Filter off, which waits until selected). A build never runs beside a capture or a Share export, and a refusal sending again can't change waits for Retry. The server unpacks it into the scan's directory.

A cloud on each space shows what the server holds: an outline for the map, a green check for everything. Nothing is sent during a capture. The server then:
- shares join fine-tunes edited on its web 3D view back to the phone;
- can ask for a focus scan of a region, for example where its toy change evaluator saw a rescan differ. The server (the `scan4d-server` repo) keeps the fleet's devices, maps and scans in one place, the start of server-directed scanning. See REQ-038.

TestFlight builds start with the lab's server set; App Store and Xcode builds start with none. When the server asks for its password and none is stored, a tapped Sync opens Settings at the password field first, then goes on when Settings closes.

> **Note:** For a comprehensive list of all features, architecture diagrams, and detailed implementation status, please see [REQUIREMENTS.md](REQUIREMENTS.md).
>
> See also: **[CHANGELOG.md](CHANGELOG.md)** · **[RELEASE.md](docs/RELEASE.md)** · **[TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)** · **[SCAN_GUIDANCE.md](docs/SCAN_GUIDANCE.md)**

## Architecture

```
wisescan-ios/
│  # App shell, settings, guides
├── AppDelegate.swift            # App lifecycle, orientation locking
├── AppConstants.swift           # Centralized UI constants, app defaults, pipeline tuning
├── ContentView.swift            # Tab bar (Dashboard, Capture, Scans) + LiDAR check
├── DashboardView.swift          # Lab server status, wearable glasses connect, 360° camera card, lab to-do list
├── SettingsView.swift           # Control plane, export settings, capture mode, Developer Mode
├── ButtonStyles.swift           # Shared button styles
├── AdaptiveActionLabel.swift    # Action-button label that carries its icon on iPad and drops it on iPhone
├── PermissionsOverlay.swift     # Camera/AR permission request UI
├── UserGuideView.swift          # In-app workflow guide (documentation that lives in SwiftUI)
├── DeviceConnectionGuides.swift # Device setup walkthroughs (Meta Ray-Ban, 360° cameras)
├── LocationManager.swift        # GPS/heading updates for scan metadata
├── DemoDataSeeder.swift         # Orphan scan discovery + SwiftData seeding
├── TestDataGenerator.swift      # Mock camera intrinsics for testing
│  # Room-scan capture
├── CaptureView.swift            # Live capture UI, recording controls, scan HUD, capacity metrics
├── CaptureView+Recording.swift  # Record start/stop, stop decision menu, save flow, deferred naming
├── CaptureView+Extend.swift     # Pin & Extend: mid-session boundary link + session reset
├── CaptureView+Alignment.swift  # Link Adjacent: cross-session relocalization + alignment flow
├── AlignmentOverlayView.swift   # Cross-session alignment overlay (distance + tracking state)
├── ARCoverageView.swift         # ARKit session, mesh wireframe (AR), point cloud (VR), OBJ export
├── PointCloudManager.swift      # VR mode: live depth point cloud rendering via Metal shaders
├── VoxelGrid.swift              # Metal voxel grid for VR accumulated point cloud
├── VoxelGrid+Extraction.swift   # Mesh-extraction packing for the VR voxel grid
├── FaceBlurOverlay.swift        # Live red-eye privacy indicator (ARKit stencil) + pixelation utility for exports
├── FrameCaptureSession.swift    # Room-scan capture: automatic 12MP stills, depth, poses, the rig's tapped still
├── CaptureExposurePolicy.swift  # Short-exposure cap on ARKit's camera (1/500 to 1/120 s), both capture modes
├── DelegateWorkMeter.swift      # Per-frame AR delegate timing during a room scan
├── StillnessReticle.swift       # Capture-quality reticle: ring fills as device settles (360° rig tap)
├── PhotoCoverageGrid.swift      # World-space voxel grid tracking photo coverage (amber overlay source)
├── SweepCoverageRecorder.swift  # Records which parts of the room the LiDAR sweep looked at (sweep_coverage.bin)
├── SweepCoverageGrid.swift      # Per-cell sweep observation counters (free / surface / visit)
├── SweepFrameThrottle.swift     # Admission gate: which ARKit frames the sweep-coverage recorder consumes
├── SweepCoverageFile.swift      # On-disk format for the per-scan sweep coverage grid
├── SweepCoverageReadout.swift   # Developer readout of the live sweep-coverage counters
├── TrackingStability.swift      # Mid-scan tracking snap/stability detector
├── ScanCoach.swift              # Rules engine: 4-tier priority coaching tips (~1Hz evaluation)
├── CoachBarView.swift           # Coach bar UI: color-coded tip banner with swipe-to-dismiss
├── SpaceAnalyzer.swift          # Pre-scan analysis engine: 360° yaw tracker, report builder
├── ScanAnalysisReportView.swift # Space analysis report modal: per-check pass/warn/skip cards
├── CaptureFlash.swift           # Screen flash for every saved still (full for a tapped still, softer for automatic ones)
├── ScreenAwake.swift            # Keeps auto-lock off while recording or exporting
│  # Focus scan (partial scan of one region)
├── ARStillCaptureSession.swift  # Focus-scan still engine: blur/region/spacing gates, coverage, logs, manifest
├── ARStillCaptureGates.swift    # Pure gate math (image-motion smear, gyro peak, region view, coverage bins)
├── ARStillCaptureController.swift # Focus-scan controller (start/stop, stats polling)
├── CaptureView+StillCapture.swift # Focus scan start/stop, filing as a scan, region box placement
├── FocusRegion.swift            # Focus region box, detail levels, placement in a map's raw frame
├── FocusRegionEditorView.swift  # Draw a focus region on a room scan's mesh
├── FocusRegionInbox.swift       # Focus region import by deep link or file
├── FocusCaptureHUD.swift        # Focus-scan HUD + coverage dial
├── FocusScanStorage.swift       # Filing a capture as a focus scan; card thumbnail
├── FocusScanViews.swift         # Focus-scan photo grid
├── ScanExportManager+Focus.swift # Focus-scan export zip + fail-closed person check
│  # 360° still source (Ricoh Theta rig)
├── ThetaCameraManager.swift     # 360° camera: connect, roster, shutter, still downloads
├── ThetaCameraManager+OSC.swift # OSC (Open Spherical Camera) Web API v2.1 transport
├── ThetaCameraManager+ScanCapture.swift # Persists live-scan stills: equirect JPEG + pose sidecar
├── ThetaCameraManager+StillFormat.swift # Still-resolution menu for the connected camera
├── ThetaCameraManager+StillMotion.swift # Exposure-sway measurement + capture guards
├── ThetaBLEManager.swift        # Production BLE: pair, wake-from-nap, shutter with file-URL push
├── ThetaBLEManager+Link.swift   # Link establishment: power-on wait, scan, connect, identity
├── ThetaBLEManager+Delegates.swift # CoreBluetooth delegate callbacks
├── ThetaBLEProbe.swift          # Developer Mode GATT bench for exploring BLE devices
├── ThetaCaptureCue.swift        # Visual/haptic capture cue driven by the manager's capture state
├── ThetaGravity.swift           # The camera's own gravity vector at capture, recovered from the still
├── StillSpacingRings.swift      # Floor rings marking taken stills, with a live spacing verdict
├── RigModel.swift               # Rig geometry model and solve bounds
├── RigHeightSheet.swift         # Rig-height editor (imperial/metric, own keypad)
├── OperatorRigMask.swift        # Per-still mask of the operator, grip and rod
├── EquirectYawAnchor.swift      # Yaw basin for the rig solve from the phone's keyframes (solver v8)
├── PhotometricRigSolver.swift   # Photometric rig solver (v15) that ships the poses
├── EquirectPostCalibration.swift # Per-scan 360° rig solve at Process time (bakes cam_transform + provenance)
├── EquirectFaceExport.swift     # Cube faces cut from equirects at baked poses (export + colorize probe)
├── EquirectGPU.swift            # Metal equirect sampling/reprojection
├── FaceDepthRender.swift        # Depth for a synthetic cube face, rasterized from the scan's own mesh
├── EquirectPrivacyBlur.swift    # Per-still person blur for exported equirects (hard invariant)
├── EquirectPrivacyBlur+Projection.swift # Equirect/cube-face geometry for the privacy pass
├── EquirectPrivacyBlur+Vision.swift # Per-face person segmentation for the privacy pass
│  # Process step and registration
├── ScanPostprocessor.swift      # Process step: downloads, calibration, registration bake, ghost proxy + bad-scan check
├── PlaneRegistration.swift      # Gravity-locked 4-DOF plane registration solver (canonical frame)
├── SaveRegistration.swift       # registration.json sidecar + transactional mesh/roomplan bake
├── RoomPlanExporter.swift       # roomplan.json / roomplan_raw.json sidecar writers
├── DerivedSurfaces.swift        # derived_surfaces.json sidecar: levels/ramps recovered from the classified mesh
├── FeaturePointCloudFile.swift  # arkit_features.bin: ARKit sparse feature cloud (id + xyz) on disk
├── DepthPNG.swift               # Single decoder for the pipeline's 16-bit depth PNGs
│  # Scans, preview, linking
├── LocationDetailView.swift     # Per-location scan management, share, sync, preview
├── ScansListView.swift          # Scan cards, location groups, Process/share gates, sync badges
├── ShareFormatMenu.swift        # Share asks for its format: Scan4D, OBJ, PLY or USDZ
├── ScanStore.swift              # Data models (ScanLocation, CapturedScan, ScanStats, capacity)
├── ThumbnailCache.swift         # Scan card thumbnail cache
├── StitchingMetadata.swift      # Boundary-anchor link manifest (stitching.json)
├── StitchLinkModel.swift        # Structured logging for the stitch-link subsystem
├── StitchGraphModel.swift       # Linked-scan graph model (nodes, edges, components)
├── StitchGraphView.swift        # Node-graph visualization of linked scans
├── CombinedMeshView.swift       # Combined SceneKit view of all linked scans
├── MeshPreviewView.swift        # SceneKit 3D mesh preview with vertex colors or height gradient
├── MeshPreviewView+KeyframeFrustums.swift # Camera frustum markers for stills/frames in preview
├── MeshPreviewView+SemanticLabels.swift # Semantic label detail, legend filter, tap-to-identify
├── MeshPreviewView+Timeline.swift # Time scrubber across a location's room generations
├── ScanTimelineBar.swift        # The preview's bottom-docked time scrubber
│  # Export
├── ScanExportManager.swift      # Export packaging (Scan4D, OBJ, PLY, USDZ)
├── InterruptedExports.swift     # At launch, fails the exports a closed app left in flight
├── MeshConverter.swift          # OBJ→PLY and OBJ→USDZ mesh conversion
├── MeshParser.swift             # Wavefront OBJ parser for RealityKit MeshResource
├── VertexColorAccumulator.swift # Vertex coloring: frame selection, top-K observations, consensus-median reduce
├── VertexColorGPU.swift         # Metal compute path for per-frame vertex projection (CPU fallback stays in lockstep)
│  # Control plane (scan4d-server)
├── ControlPlaneSync.swift       # When and how the app syncs with the control plane
├── ControlPlaneClient.swift     # Control plane HTTP client: host parsing, requests, error text
├── ControlPlaneSession.swift    # URLSession for the control plane, and its certificate rule
├── ControlPlaneManifest.swift   # Sync manifest snapshot (SwiftData on main, files off main)
├── ScanBundle.swift             # Each scan's sync bundle: version, cache, background upload (BundleSync)
├── SyncViews.swift              # Sync badge, scan card sync line, pending-bundles checklist
├── DeviceIdentity.swift         # This phone's identity for the control plane
├── ControlPlaneSettingsSection.swift # Settings → Control plane
├── ControlPlanePasswordPrompt.swift # Password retry prompt and deferred action replay
├── ControlPlaneSpaceSyncButton.swift # Sync to Lab Server on a space
├── ControlPlaneTodoCard.swift   # Dashboard to-do list: focus scans the lab asked for
│  # Peripherals and diagnostics
├── MetaWearableManager.swift    # Meta Ray-Ban DAT SDK lifecycle, streaming, proxy frames
├── PerfDiag.swift               # Perf diagnostics: main-thread watchdog, frame gaps, I/O backlog
├── LocalizationDiag.swift       # Relocalization diagnostics logging
├── DiagnosticsLogExport.swift   # On-device export of the app's own unified-log entries
└── Shaders/
    ├── PointCloud.metal         # VR point cloud vertex/fragment shaders
    ├── Bloom.metal              # Bloom post-processing shader
    ├── Wireframe.metal          # AR wireframe rendering shaders
    ├── VertexColorProject.metal # GPU vertex-color projection kernel (occlusion + anti-bleed guards)
    └── EquirectReproject.metal  # Equirect sampling kernels (cube faces, calibration)
```

## Export Formats & Backend Ingestion

The app has one capture export, **Scan4D**, a superset of everything the scan captured, plus three
single-file mesh exports. The filename convention is:
`scan4d_{locationName}_{scanName}_{format}_{timestamp}_{uuid}.{ext}`

| Format | Extension | Contents | Viewer |
| :--- | :--- | :--- | :--- |
| **Scan4D** | `.zip` | `scan4d_metadata.json`, the Polycam payload (`images/`, `depth/`, `confidence/`, `cameras/`, `mesh_info.json`), `mesh.obj` (with captured vertex colors) + `face_classes.bin`, `roomplan*.json`, `registration.json`, `arkit_features.bin`, `sweep_coverage.bin`, `stitching.json`; 360° scans add `equirect_stills/` + cube faces at baked poses with their masks | The lab server (scan4d-flows), which trains splats from it and makes the formats below |
| **OBJ** | `.obj` | Single mesh file with captured vertex colors | MeshLab, Blender |
| **PLY** | `.ply` | Converted mesh with captured vertex colors | MeshLab, CloudCompare |
| **USDZ** | `.usdz` | Converted mesh via ModelIO, with vertex colors | iOS Quick Look (native) |

The layouts other tools read are made from the Scan4D export on the lab server, by the
`scan4d-convert` pipeline in the flows repo (scan4d-flows): a **Nerfstudio dataset** that
Nerfstudio and LichtFeld Studio load as-is, and the input bundle
[flame3d-core](https://github.com/openflam/flame3d-core) reads (its contract is in
[tools/scan4d-to-flame3d](tools/scan4d-to-flame3d/README.md)). The app exported those itself until
they were folded into Scan4D, along with Polycam; scans and settings that held one of those
formats export Scan4D. See [schemas/README.md](schemas/README.md).

### Example: Scan4D Export
```
scan4d_Kitchen_scan1_scan4d_1710520000_a1b2c3d4.zip/
├── scan4d_metadata.json    # GPS tags, Location ID, `export_format`, `hardware_device_model`, & `face_anchors`
├── mesh.obj                # ARKit mesh with captured vertex colors (canonical frame), + face_classes.bin
├── roomplan.json           # RoomPlan surfaces and objects (+ roomplan_raw.json)
├── registration.json       # raw→canonical transform relating the mesh to the cameras
├── arkit_features.bin       # ARKit sparse feature cloud (id + xyz, raw capture frame)
├── sweep_coverage.bin       # Where the sweep looked: per-cell free/surface/visit counts (raw capture frame)
├── images/                 # RGB frames (JPEG, ~2fps adaptive)
│   ├── frame_00000.jpg
│   └── ...
├── depth/                  # 16-bit PNG depth maps (millimeters)
│   ├── frame_00000.png
│   └── ...
├── confidence/             # 8-bit PNG ARKit depth confidence maps (0=Low, 1=Med, 2=High)
│   ├── frame_00000.png
│   └── ...
├── cameras/                # Per-frame Polycam JSON configs
│   ├── frame_00000.json
│   └── ...
├── masks/                  # 360° scans only: operator/rig keep-masks for the cube faces
├── equirect_stills/        # 360° scans only: privacy-passed equirects + pose sidecars
│   ├── still_0000.JPG
│   ├── still_0000.json
│   └── ...
└── mesh_info.json          # Frame counts and image dimensions
```

### Backend Receivers

Scan4D syncs to the lab's stack. The sibling repos, as they describe themselves today:

- **`scan4d-server`** (private): the control plane. Device registry, the inventory of spaces, maps, scans and links, a working directory served as S3 by its own Versity, each synced scan's bundle unpacked there by a job queue, join fine-tunes shared back to the phone, focus-scan tasks, a web app with a 3D map view (with each scan's photos where they were taken), and Prefect with a docker worker for the flows. Its README is the design and the API contract (REQ-038).
- **`scan4d-flows`** (private): the flows deployed into that Prefect. `scan4d-splat` (a room scan or focus-scan dump to a trained Gaussian splat: normalize, SfM poses, priors, region masks, LichtFeld training; GPU), `scan4d-convert` (a Nerfstudio dataset or a flame3d bundle from a scan), `eagle-splat` (Eagle Max captures), `spark-build-lod` (a Spark level-of-detail fileset for ARENA).
- **[wisescan-upload](https://github.com/WiseLabCMU/wisescan-upload):** an HTTP/3 upload gateway (Caddy in front of VersityGW) that received the exports earlier builds' Upload sent to a URL configured in Settings. The app no longer uploads there: Share covers files for other tools, and Sync covers the lab.
- **[wisescan-ingestion](https://github.com/WiseLabCMU/wisescan-ingestion):** a NATS JetStream stack that persists time-series binary streams with per-session JWT authentication. Not on the export path today; the candidate receiver for a streaming mode (REQ-018).

The Scan4D export is also each scan's sync bundle, with the relocalization map and the proxy meshes added; [docs/design/sync-bundle.md](docs/design/sync-bundle.md) is the design.

## Privacy Filtering

On by default. Switched off on the Capture screen, it turns itself back on after 24 hours (Developer Mode: 12 h, 24 h, 1 week or none). Each synced scan tells the lab server whether the filter was on.

When enabled (toggle on Capture screen):

- **Mesh**: ARKit person segmentation removes human-shaped geometry from the wireframe overlay and exported OBJ
- **Live indicator**: Detected people are marked on-screen with a cheap red-eye marker driven by ARKit's segmentation stencil — no per-frame Vision pass or pixelation render (that starves tracking); the saved-frame blur below is the actual privacy guarantee
- **RAW Frames**: Person regions are pixelated in saved JPEG images (from the ARKit stencil, with a Vision fallback if the stencil is ever unavailable, so a person is never saved unblurred); one body-center anchor per person is unprojected to 3D
- **Depth Maps**: Person regions are zeroed out in 16-bit depth exports

## Quick Start

1. Open the Xcode project in Xcode
2. Set your development team signing in the target settings
3. Build and deploy to an ARKit-capable device (LiDAR recommended for full mesh + depth capture)
4. *(Optional)* Set your lab server in Settings → Control plane (gear icon), to sync spaces to it
5. *(Optional 360°)* On the Dashboard, tap **+ Add Ricoh Theta 360° Camera** — pick it from the Bluetooth list and confirm the pairing code on the camera screen once. After that, **Connect** wakes and joins it automatically, and a full-sphere still fires with every keyframe pause.
6. Go to Capture → tap record → scan → tap stop and choose **Save & End** (or **Save & Scan Adjacent** to continue into the next room)
7. Once the save pipeline finishes, name your space and select its workflow intent — **Rescan** (the same space over time) or **Link Adjacent** (a neighboring space). You will be routed to the Scans tab with a progress overlay while mesh export and data extraction finishes in the background.
8. Post-processing (pending 360° downloads, rig calibration, plane registration into the location's canonical frame, ghost proxy) runs automatically after save and when you open the location; sharing, the scan's sync bundle, rescan, and connect wait for it to complete. Tap the card's **Color** button to vertex-color the mesh — it finishes any remaining structural steps first, so one tap always ends colored.
9. In the Scans tab, continue a Location with **Rescan Space** (re-capture the same area over time — the temporal dimension) or **Link Adjacent Space** (capture and stitch a neighboring area — the spatial dimension). Either way a colored ghost-mesh overlay (default: magenta, configurable in Settings) shows the previous scan for alignment — rescans auto-align into the location's canonical frame — and you can drop a boundary link mid-scan with **Pin & Extend**.

## Testing Guidelines (Meta Wearables)

The Meta Wearables DAT SDK relies on specific Xcode build configurations that cannot be safely executed automatically via typical text edits, as it will corrupt the `.pbxproj`. You will need to manually perform these setup steps in Xcode:

1. **Add the Swift Package**
   In Xcode, go to `File > Add Package Dependencies...` and enter the repository URL: `https://github.com/facebook/meta-wearables-dat-ios`. Add the `meta-wearables-dat-ios` library to the `wisescan-ios` target.

2. **Gather Meta Credentials (Optional)**
   Ensure you have your `MetaAppID`, `ClientToken`, and `TeamID` registered from the Meta Wearables Developer Center. Keep the real values on your machine only: the privacy guard refuses a staged plist that carries them (see CONTRIBUTING, Credentials). Inject these into `Custom-Info.plist` locally without staging the file (or keep them blank to function in Developer Mode). 

3. **Enable Developer Mode in Meta View App**
   If you are testing without registered production credentials:
   - Open the official **Meta View** companion app on your testing iPhone.
   - Navigate to Settings > Developer Mode and toggle it **ON**.
   - When you tap "Connect" in Scan4D, it will deep-link to Meta View. You must explicitly tap "Allow" on the developer prompt to authorize the local stream.

4. **Verification Steps**
   - **Compilation Check**: The project should compile cleanly with SPM dependencies linked.
   - **Pairing Check**: `DashboardView` should automatically list the Meta Ray-Bans once the Meta View companion app broadcasts their availability.
   - **Hardware Trigger Check**: Clicking the capture button on the physical glasses should instantly initiate the frame drop into `scan4d_metadata.json` proxy packages, and the glasses' LED should illuminate.

## License

This project is licensed under the BSD 3-Clause License - see the [LICENSE](LICENSE) file for details.
