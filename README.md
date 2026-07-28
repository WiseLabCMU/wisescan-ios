# Scan4D

Scan4D is the time-series reality capture application for the WiSEScan platform. It acts as an advanced sensor client designed to bridge high-fidelity device data with backend reconstruction servers.

**Requires:** iOS 17.0+ · ARKit-capable iPhone or iPad · Xcode 15+  
**Recommended:** LiDAR-equipped device (iPhone/iPad Pro) for full mesh + depth capture

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
- **Post-Scan Processing & Plane Registration:** The save path persists raw artifacts only; the room layout (RoomPlan) builds automatically seconds after save, and everything else derived finishes via an explicit **Process** step (per-card button or bulk "Process All" with per-tile progress): **plane registration** aligns each rescan into its location's **canonical coordinate frame** (gravity-locked 4-DOF wall/floor matching with an observability gate, so unobservable solves are refused rather than guessed), a lightweight **ghost proxy** is generated for future rescan overlays, and camera-based vertex coloring is applied. A trusted registration is baked transactionally (mesh + room layout + `registration.json` sidecar move together, with rollback on failure) and bundled in exports. Upload, export, rescan, and connect are **gated until processing completes**, and a bad-scan check warns right after save when a capture produced no usable room data (so you can redo it while still in the room). During a rescan, the live ghost auto-seats against detected planes.
- **Linked-Scan Graph & Combined Mesh:** Each boundary link is recorded in a per-location `stitching.json` manifest (paired anchor transforms + compass headings) and bundled in every Scan4D export. The Scans tab visualizes chained scans as a node graph and can render all linked scans together in one combined-mesh viewer.
- **Privacy Filtering:** A live red-eye indicator marks detected people on-screen, and person regions are pixelated in exported frames and zeroed out of depth maps. All three are driven by ARKit's person-segmentation stencil (no per-frame Vision pass); one body-center 3D anchor per person is unprojected from depth for red privacy markers on mesh previews.
- **Capture Quality (Hi-Res Stillness Keyframes):** When the device is held still, the app captures a native-resolution still photo (`ARSession.captureHighResolutionFrame`, up to ~12MP) as a sharp keyframe alongside the video-stream frames — the AR stream stays on a mesh-friendly format. A center reticle fills as the device settles, and a shutter flash/click/haptic confirms each keyframe. In AR mode, the coverage overlay shows three states: green (unscanned), amber (depth captured, no photo), and clear camera feed (photo-grade). Photo coverage is tracked on a world-space voxel grid stamped from each keyframe's depth map (so surfaces behind walls are never falsely marked), and the coach nudges you to pause on the amber areas when photo coverage falls behind the mesh. Keyframes are flagged in exports (`is_keyframe`) and weighted higher during vertex coloring; `scan4d_metadata.json` records a `photo_coverage` fraction so backends can triage datasets.
- **Scan Capacity Metrics:** Live polygon count, anchor count, drift tracking, and session duration with a composite capacity indicator that warns users when approaching ARKit session limits.
- **Developer Mode:** Toggleable debugging tools — synthetic IMU/camera/depth injection for Simulator testing and performance diagnostics — with a persistent banner across all views.
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
├── DashboardView.swift          # Upload server status card, wearable glasses connect
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
├── ScanPostprocessor.swift      # Process step: registration bake, ghost proxy, colorize + bad-scan check
├── PlaneRegistration.swift      # Gravity-locked 4-DOF plane registration solver (canonical frame)
├── SaveRegistration.swift       # registration.json sidecar + transactional mesh/roomplan bake
├── RoomPlanExporter.swift       # roomplan.json / roomplan_raw.json sidecar writers
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
├── VertexColorAccumulator.swift # Normals-based default coloring, on-demand vertex coloring, ARWorldMap export
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
    └── Wireframe.metal          # AR wireframe rendering shaders
```

## Export Formats & Backend Ingestion

Each export format includes **only** the data relevant to that format. The filename convention is:
`scan4d_{locationName}_{scanName}_{format}_{timestamp}_{uuid}.{ext}`

| Format | Extension | Contents | Viewer |
| :--- | :--- | :--- | :--- |
| **Scan4D** | `.zip` | `scan4d_metadata.json`, `relocalization.worldmap`, + full Polycam payload | Scan4D server workflows |
| **Polycam** | `.zip` | `images/`, `depth/`, `cameras/`, `mesh_info.json` | Polycam raw data import |
| **RAW** | `.zip` | `images/`, `depth/`, `confidence/`, `transforms.json` | Nerfstudio, COLMAP |
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
5. Go to Capture → tap record → scan → tap stop and choose **Save & End** (or **Save & Scan Adjacent** to continue into the next room)
6. Once the save pipeline finishes, name your space and select its workflow intent — **Rescan** (the same space over time) or **Link Adjacent** (a neighboring space). You will be routed to the Scans tab with a progress overlay while mesh export and data extraction finishes in the background.
7. Tap **Process** on the scan card (or **Process All** on the location) to finish the scan on-device — plane registration into the location's canonical frame, ghost-proxy generation, and camera-based vertex coloring. Upload, export, rescan, and connect unlock when processing completes.
8. In the Scans tab, continue a Location with **Rescan Space** (re-capture the same area over time — the temporal dimension) or **Link Adjacent Space** (capture and stitch a neighboring area — the spatial dimension). Either way a colored ghost-mesh overlay (default: magenta, configurable in Settings) shows the previous scan for alignment — rescans auto-align into the location's canonical frame — and you can drop a boundary link mid-scan with **Pin & Extend**.

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
