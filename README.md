# Scan4D

Scan4D is the time-series reality capture application for the WiSEScan platform. It acts as an advanced sensor client designed to bridge high-fidelity device data with backend reconstruction servers.

**Requires:** iOS 17.0+ · ARKit-capable iPhone or iPad · Xcode 15+  
**Recommended:** LiDAR-equipped device (iPhone/iPad Pro) for full mesh + depth capture  
**Optional:** rig-mounted Ricoh Theta (X fully supported; Z1 Wi-Fi-only) as a 360° still source

**Backend Integration:** Receivers: [wisescan-upload](https://github.com/WiseLabCMU/wisescan-upload) (testing fallback) and [wisescan-ingestion](https://github.com/WiseLabCMU/wisescan-ingestion) (production Prefect pipeline).

## Device Support

| Capability | Full Mode (LiDAR) | Lite Mode (No LiDAR) | Proxy Mode |
| :--- | :--- | :--- | :--- |
| **Devices** | iPhone Pro, iPad Pro | iPhone 16, older iPhones/iPads | Meta Ray-Ban, Glasses |
| **RGB Frames** | ✅ | ✅ | ✅ Streamed via Bluetooth |
| **Camera Poses** | ✅ ARKit tracking | ✅ ARKit tracking | ❌ |
| **Depth Maps** | ✅ LiDAR depth | ❌ | ❌ |
| **Real-time Mesh** | ✅ Scene reconstruction | ❌ | ❌ |
| **Coverage Overlay** | ✅ Wireframe | ❌ | ❌ |
| **Privacy Markers** | ✅ 3D face anchors | ❌ (2D blur only) | ❌ |
| **Mesh Preview** | ✅ Colored 3D model | ❌ | ❌ |
| **Server Reconstruction** | Full pipeline | Photogrammetry only | Photogrammetry only |

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
- **Space Staging Analyzer:** Optional pre-scan analysis phase that checks room conditions before recording. Tap "Analyze" to start a 360° sweep — the app measures ambient lighting, detects doors/screens via RoomPlan, and checks for people in the scene. A report modal summarizes findings with actionable tips (privacy-filter-aware people messaging).
- **Lite Mode:** Non-LiDAR devices capture images + camera poses for server-side photogrammetry. A persistent banner indicates lite mode. *(Note: Lite mode is only available in local debug builds for testing. TestFlight and App Store releases strictly require LiDAR-equipped devices.)*
- **Scan4D (Rescan & Link Adjacent):** Group scans by Location and set the workflow intent when saving. The two intents capture different dimensions of a space: **Rescan Space** is *temporal* — re-capture the same physical area at a later time so the backend can diff or merge versions; **Link Adjacent Space** is *spatial* — capture a neighboring area and stitch the chunks into one larger model. Both relocalize against the previous scan's `ARWorldMap` and show a configurable ghost-mesh overlay (default: magenta) of that prior capture. Adjacent chunks join at a shared boundary anchor: drop one mid-scan with **Pin & Extend**, or relocalize back to it in a later session through a guided alignment overlay.
- **Post-Scan Processing & Plane Registration:** The save path persists raw artifacts only; the room layout (RoomPlan) builds automatically seconds after save, and everything else derived finishes via an explicit **Process** step (per-card button or bulk "Process All" with per-tile progress): **plane registration** aligns each rescan into its location's **canonical coordinate frame** (gravity-locked 4-DOF wall/floor matching with an observability gate, so unobservable solves are refused rather than guessed), and a lightweight **ghost proxy** is generated for future rescan overlays. Post-processing also runs automatically after save and when landing on a location, so the explicit button is mostly recovery. **Coloring is its own verb**: the scan card's primary **Color** button (and bulk Color in both list toolbars, on stitch-graph clusters, and in the combined render) finishes any pending structural steps, then applies camera-based vertex coloring — Metal GPU projection with per-frame LiDAR depth occlusion and a consensus-median reduce; 360° scans can optionally color from cube faces as a pose-quality probe. A trusted registration is baked transactionally (mesh + room layout + `registration.json` sidecar move together, with rollback on failure) and bundled in exports. Upload, export, rescan, and connect are **gated until processing completes**, and a bad-scan check warns right after save when a capture produced no usable room data (so you can redo it while still in the room). During a rescan, the live ghost auto-seats against detected planes.
- **Derived Levels & Ramps (Multi-Level Spaces):** RoomPlan models one floor per room, so a step, a landing, a mezzanine, or a shallow ramp comes back as bare mesh with no plane to represent it. At Process time the ghost-proxy build re-reads the scan's *own* classified mesh (`mesh.obj` + the per-face class sidecar) and recovers those walkable surfaces as oriented planes, written to a `derived_surfaces.json` sidecar and drawn in the mesh preview's semantic overlay. Their categories are deliberately `level` and `ramp` rather than `floor`, so nothing can feed them into a coordinate solve by accident. Wall quads are now **cell-backed**: a RoomPlan quad draws and subtracts mesh only where the classified mesh actually backs it, cell by cell — and a quad that explains less than half the geometry inside its own footprint is **demoted**, neither baking nor subtracting, so a curved or bowed wall keeps its real mesh instead of being flattened to a chord. The sidecar is an on-device artifact; it is not part of any export bundle.
- **Linked-Scan Graph & Combined Mesh:** Each boundary link is recorded in a per-location `stitching.json` manifest (paired anchor transforms + compass headings) and bundled in every Scan4D export. The Scans tab visualizes chained scans as a node graph and can render all linked scans together in one combined-mesh viewer.
- **Privacy Filtering:** A live red-eye indicator marks detected people on-screen, and person regions are pixelated in exported frames and zeroed out of depth maps. All three are driven by ARKit's person-segmentation stencil (no per-frame Vision pass); one body-center 3D anchor per person is unprojected from depth for red privacy markers on mesh previews.
- **Capture Quality (Hi-Res Stillness Keyframes):** When the device is held still, the app captures a native-resolution still photo (`ARSession.captureHighResolutionFrame`, up to ~12MP) as a sharp keyframe alongside the video-stream frames — the AR stream stays on a mesh-friendly format. A center reticle fills as the device settles, and a shutter flash/click/haptic confirms each keyframe. In AR mode, the coverage overlay shows three states: green (unscanned), amber (depth captured, no photo), and clear camera feed (photo-grade). Photo coverage is tracked on a world-space voxel grid stamped from each keyframe's depth map (so surfaces behind walls are never falsely marked), and the coach nudges you to pause on the amber areas when photo coverage falls behind the mesh. Keyframes are flagged in exports (`is_keyframe`) and weighted higher during vertex coloring; `scan4d_metadata.json` records a `photo_coverage` fraction so backends can triage datasets.
- **360° Still Source (Ricoh Theta):** A rig-mounted Theta captures a full-sphere still at every stillness keyframe, giving reconstruction all-direction imagery the phone's frustum can't see. Connect is BLE-first: pick the camera from a named Bluetooth list, one-time passkey bond, wake-from-sleep over BLE, then an automatic Wi-Fi join; the shutter rides BLE when the link is up (the new file's URL arrives as a push — no polling). Camera poses are solved **per scan at Process time** against the completed mesh (yaw and mount sag are per-scan nuisances; the measured rig height anchors the solve) and baked into each still's sidecar with provenance. A multi-camera roster switches bodies per collection. Camera-side originals are deleted after verified transfer — raw equirects capture bystanders in every direction — and stills leave the device only through the export privacy passes. See REQ-033 in [REQUIREMENTS.md](REQUIREMENTS.md).
- **Scan Capacity Metrics:** Live polygon count, anchor count, drift tracking, and session duration with a composite capacity indicator that warns users when approaching ARKit session limits.
- **Developer Mode:** Toggleable debugging tools — synthetic IMU/camera/depth injection for Simulator testing, performance diagnostics, and a **Force Rebuild Artifacts** switch that re-runs the derived-artifact build (ghost proxy, dynamic mesh, derived surfaces) on an already-current scan so its build diagnostics can be re-read — with a persistent banner across all views.
- **Export & Scan Capture Data:** Export native mesh formats (OBJ, PLY, USDZ) along with RAW RGB, depth, and camera poses governed by motion-blur rejection and overlapping metrics.
- **Server Integration:** Direct HTTP upload to configured server URLs for edge or cloud reconstruction orchestration.

> **Note:** For a comprehensive list of all features, architecture diagrams, and detailed implementation status, please see [REQUIREMENTS.md](REQUIREMENTS.md).
>
> See also: **[CHANGELOG.md](CHANGELOG.md)** · **[RELEASE.md](docs/RELEASE.md)** · **[TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)** · **[SCAN_GUIDANCE.md](docs/SCAN_GUIDANCE.md)**

## Architecture

```
wisescan-ios/
├── AppDelegate.swift            # App lifecycle, orientation locking
├── AppConstants.swift           # Centralized UI constants, app defaults, pipeline tuning
├── ContentView.swift            # Tab bar (Dashboard, Capture, Scans) + LiDAR check
├── DashboardView.swift          # Upload server status, wearable glasses connect, 360° camera card
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
├── FrameCaptureSession.swift    # RAW data capture (RGB, depth, poses), stillness detection, hi-res keyframes
├── StillnessReticle.swift       # Capture-quality reticle: ring fills as device settles for a keyframe
├── PhotoCoverageGrid.swift      # World-space voxel grid tracking photo coverage (amber overlay source)
├── ThetaCameraManager.swift     # 360° camera: connect, roster, shutter, still downloads (+OSC/+ScanCapture/+StillFormat)
├── ThetaBLEManager.swift        # Production BLE: pair, wake-from-nap, shutter with file-URL push (+Link/+Delegates)
├── ThetaBLEProbe.swift          # Developer Mode GATT bench for exploring BLE devices
├── EquirectPostCalibration.swift # Per-scan 360° rig solve at Process time (bakes cam_transform + provenance)
├── RigCalibrationSolver.swift   # Rig geometry solver: yaw circle, elevation sweep, bounded refine
├── RigCalibrationManager.swift  # Developer Mode calibration bench
├── EquirectFaceExport.swift     # Cube faces cut from equirects at baked poses (export + colorize probe)
├── EquirectGPU.swift            # Metal equirect sampling/reprojection
├── EquirectPrivacyBlur.swift    # Per-still person blur for exported equirects
├── ScanPostprocessor.swift      # Process step: downloads, calibration, registration bake, ghost proxy + bad-scan check
├── PlaneRegistration.swift      # Gravity-locked 4-DOF plane registration solver (canonical frame)
├── SaveRegistration.swift       # registration.json sidecar + transactional mesh/roomplan bake
├── RoomPlanExporter.swift       # roomplan.json / roomplan_raw.json sidecar writers
├── DerivedSurfaces.swift        # derived_surfaces.json sidecar: levels/ramps recovered from the classified mesh
├── LocationDetailView.swift     # Per-location scan management, export, upload, preview
├── ScansListView.swift          # Scan cards, location groups, Process/upload gates, format picker
├── StitchingMetadata.swift      # Boundary-anchor link manifest (stitching.json)
├── StitchLinkModel.swift        # Structured logging for the stitch-link subsystem
├── StitchGraphModel.swift       # Linked-scan graph model (nodes, edges, components)
├── StitchGraphView.swift        # Node-graph visualization of linked scans
├── CombinedMeshView.swift       # Combined SceneKit view of all linked scans
├── MeshPreviewView.swift        # SceneKit 3D mesh preview with vertex colors or height gradient
├── MeshPreviewView+KeyframeFrustums.swift # Camera frustum markers for stills/frames in preview
├── ThumbnailCache.swift         # Scan card thumbnail cache
├── ScanStore.swift              # Data models (ScanLocation, CapturedScan, ScanStats, capacity)
├── ScanExportManager.swift      # Export packaging (Scan4D, Polycam, RAW, OBJ, PLY, USDZ)
├── MeshConverter.swift          # OBJ→PLY and OBJ→USDZ mesh conversion
├── MeshParser.swift             # Wavefront OBJ parser for RealityKit MeshResource
├── VertexColorAccumulator.swift # Vertex coloring: frame selection, top-K observations, consensus-median reduce
├── VertexColorGPU.swift         # Metal compute path for per-frame vertex projection (CPU fallback stays in lockstep)
├── MetaWearableManager.swift    # Meta Ray-Ban DAT SDK lifecycle, streaming, proxy frames
├── LocationManager.swift        # GPS/heading updates for scan metadata
├── PermissionsOverlay.swift     # Camera/AR permission request UI
├── SettingsView.swift           # Upload URL, RAW settings, capture mode, Developer Mode
├── ButtonStyles.swift           # Shared button styles
├── ScanCoach.swift              # Rules engine: 4-tier priority coaching tips (~1Hz evaluation)
├── CoachBarView.swift           # Coach bar UI: color-coded tip banner with swipe-to-dismiss
├── SpaceAnalyzer.swift          # Pre-scan analysis engine: 360° yaw tracker, report builder
├── ScanAnalysisReportView.swift # Space analysis report modal: per-check pass/warn/skip cards
├── TrackingStability.swift      # Mid-scan tracking snap/stability detector
├── PerfDiag.swift               # Perf diagnostics: main-thread watchdog, frame gaps, I/O backlog
├── LocalizationDiag.swift       # Relocalization diagnostics logging
├── UserGuideView.swift          # In-app workflow guide
├── DeviceConnectionGuides.swift # Device setup walkthroughs (Meta Ray-Ban)
├── DemoDataSeeder.swift         # Orphan scan discovery + SwiftData seeding
├── TestDataGenerator.swift      # Mock camera intrinsics for testing
└── Shaders/
    ├── PointCloud.metal         # VR point cloud vertex/fragment shaders
    ├── Bloom.metal              # Bloom post-processing shader
    ├── Wireframe.metal          # AR wireframe rendering shaders
    ├── VertexColorProject.metal # GPU vertex-color projection kernel (occlusion + anti-bleed guards)
    └── EquirectReproject.metal  # Equirect sampling kernels (cube faces, calibration)
```

## Export Formats & Backend Ingestion

Each export format includes **only** the data relevant to that format. The filename convention is:
`scan4d_{locationName}_{scanName}_{format}_{timestamp}_{uuid}.{ext}`

| Format | Extension | Contents | Viewer |
| :--- | :--- | :--- | :--- |
| **Scan4D** | `.zip` | `scan4d_metadata.json`, `relocalization.worldmap`, + full Polycam payload; 360° scans add `equirect_stills/` + cube faces at baked poses | Scan4D server workflows |
| **Polycam** | `.zip` | `images/`, `depth/`, `cameras/`, `mesh_info.json` | Polycam raw data import |
| **Nerfstudio** | `.zip` | `images/`, `depth/` (at image resolution), `confidence/`, `masks/`, `transforms.json`, `sparse_pc.ply` | Nerfstudio and LichtFeld Studio, as-is |
| **OBJ** | `.obj` | Single mesh file (no vertex colors) | MeshLab, Blender |
| **PLY** | `.ply` | Converted mesh with embedded vertex colors | MeshLab, CloudCompare |
| **USDZ** | `.usdz` | Converted mesh via ModelIO | iOS Quick Look (native) |

### Example: Scan4D Export
```
scan4d_Kitchen_scan1_scan4d_1710520000_a1b2c3d4.zip/
├── scan4d_metadata.json    # GPS tags, Location ID, `export_format`, `hardware_device_model`, & `face_anchors`
├── relocalization.worldmap # ARKit spatial anchor for Scan4D rescanning
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
├── equirect_stills/        # 360° scans only: privacy-passed equirects + pose sidecars
│   ├── still_0000.JPG
│   ├── still_0000.json
│   └── ...
└── mesh_info.json          # Frame counts and image dimensions
```

### Backend Receivers
Scan4D is designed to upload these packages directly to edge/cloud servers. Reference implementors:
- **[wisescan-upload](https://github.com/WiseLabCMU/wisescan-upload):** A simple Python FastAPI receiver that accepts `.zip` PUT requests and saves them. Best for local loopback testing.
- **[wisescan-ingestion](https://github.com/WiseLabCMU/wisescan-ingestion):** The primary production pipeline built on Prefect.io. Automatically routes data to OpenFLAME or COLMAP based on the `scan4d_metadata.json` tags.

## Privacy Filtering

When enabled (toggle on Capture screen):

- **Mesh**: ARKit person segmentation removes human-shaped geometry from the wireframe overlay and exported OBJ
- **Live indicator**: Detected people are marked on-screen with a cheap red-eye marker driven by ARKit's segmentation stencil — no per-frame Vision pass or pixelation render (that starves tracking); the saved-frame blur below is the actual privacy guarantee
- **RAW Frames**: Person regions are pixelated in saved JPEG images (from the ARKit stencil, with a Vision fallback if the stencil is ever unavailable, so a person is never saved unblurred); one body-center anchor per person is unprojected to 3D
- **Depth Maps**: Person regions are zeroed out in 16-bit depth exports

## Quick Start

1. Open the Xcode project in Xcode
2. Set your development team signing in the target settings
3. Build and deploy to an ARKit-capable device (LiDAR recommended for full mesh + depth capture)
4. Configure the upload URL in Settings (gear icon)
5. *(Optional 360°)* On the Dashboard, tap **+ Add Ricoh Theta 360° Camera** — pick it from the Bluetooth list and confirm the pairing code on the camera screen once. After that, **Connect** wakes and joins it automatically, and a full-sphere still fires with every keyframe pause.
6. Go to Capture → tap record → scan → tap stop and choose **Save & End** (or **Save & Scan Adjacent** to continue into the next room)
7. Once the save pipeline finishes, name your space and select its workflow intent — **Rescan** (the same space over time) or **Link Adjacent** (a neighboring space). You will be routed to the Scans tab with a progress overlay while mesh export and data extraction finishes in the background.
8. Post-processing (pending 360° downloads, rig calibration, plane registration into the location's canonical frame, ghost proxy) runs automatically after save and when you open the location; upload, export, rescan, and connect unlock when it completes. Tap the card's **Color** button to vertex-color the mesh — it finishes any remaining structural steps first, so one tap always ends colored.
9. In the Scans tab, continue a Location with **Rescan Space** (re-capture the same area over time — the temporal dimension) or **Link Adjacent Space** (capture and stitch a neighboring area — the spatial dimension). Either way a colored ghost-mesh overlay (default: magenta, configurable in Settings) shows the previous scan for alignment — rescans auto-align into the location's canonical frame — and you can drop a boundary link mid-scan with **Pin & Extend**.

## Testing Guidelines (Meta Wearables)

The Meta Wearables DAT SDK relies on specific Xcode build configurations that cannot be safely executed automatically via typical text edits, as it will corrupt the `.pbxproj`. You will need to manually perform these setup steps in Xcode:

1. **Add the Swift Package**
   In Xcode, go to `File > Add Package Dependencies...` and enter the repository URL: `https://github.com/facebook/meta-wearables-dat-ios`. Add the `meta-wearables-dat-ios` library to the `wisescan-ios` target.

2. **Gather Meta Credentials (Optional)**
   Ensure you have your `MetaAppID`, `ClientToken`, and `TeamID` registered from the Meta Wearables Developer Center. Inject these into `Custom-Info.plist` (or keep them blank to function in Developer Mode). 

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
