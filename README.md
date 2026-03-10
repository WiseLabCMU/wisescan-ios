# Scan4D

Scan4D is the time-series reality capture application for the WiSEScan platform. It acts as an advanced sensor client designed to bridge high-fidelity device data with backend reconstruction servers.

**Requires:** iOS 17.0+ · LiDAR-equipped iPhone or iPad · Xcode 15+

**Backend Integration:** Receivers: [wisescan-upload](https://github.com/WiseLabCMU/wisescan-upload) (testing fallback) and [wisescan-ingestion](https://github.com/WiseLabCMU/wisescan-ingestion) (production Prefect pipeline).

## Features

- **LiDAR Mesh Capture:** Real-time scene reconstruction with live wireframe overlay and quality HUD.
- **Scan4D (Time-Series):** Group scans by Location and use `ARWorldMap` caching to relocalize and rescan the exact same physical space over time.
- **Privacy Filtering:** Person segmentation removes humans from mesh; face detection blurs faces on camera feed and in exports.
- **Export & RAW Data:** Export native mesh formats (OBJ, PLY, USDZ) along with RAW RGB, depth, and camera poses.
- **Server Integration:** Direct HTTP upload to configured server URLs for edge or cloud reconstruction orchestration.

> **Note:** For a comprehensive list of all features, architecture diagrams, and detailed implementation status, please see [REQUIREMENTS.md](REQUIREMENTS.md).
>
> See also: **[CHANGELOG.md](CHANGELOG.md)** · **[RELEASE.md](RELEASE.md)**

## Architecture

```
wisescan-ios/
├── AppDelegate.swift          # App lifecycle, splash screen
├── ContentView.swift          # Tab bar (Dashboard, Capture, Workflows) + LiDAR check
├── DashboardView.swift        # Upload server status card, wearable glasses connect
├── CaptureView.swift          # Live capture UI, recording controls, scan HUD
├── ARCoverageView.swift       # ARKit scene reconstruction, person segmentation, OBJ export, vertex color accumulator
├── FaceBlurOverlay.swift      # Live face detection overlay + face blur utility for exports
├── FrameCaptureSession.swift  # RAW data capture (RGB, depth, poses → transforms.json + Polycam cameras/)
├── WorkflowsView.swift        # Scan cards, format picker, save/upload actions
├── MeshPreviewView.swift      # SceneKit 3D mesh preview with camera-sampled or height-gradient coloring
├── ScanStore.swift            # Shared data models (CapturedScan, ExportFormat, ScanStats)
└── SettingsView.swift         # Upload URL, RAW export settings, workflow guide, recommended apps
```

## Export Formats & Backend Ingestion

All exports are now bundled into a unified `.zip` archive on device. Regardless of the user's dropdown selection, the backend will receive the raw sequence data alongside the requested mesh formats. The server reads the dynamically injected `scan4d_metadata.json["export_format"]` to route the payload correctly.

| Format | Included in `.zip` Payload | Viewer |
| :--- | :--- | :--- |
| **OBJ** | `mesh.obj`, metadata, anchor map, RAW frames | MeshLab, Polycam, Blender |
| **PLY** | `mesh.ply`, metadata, anchor map, RAW frames | MeshLab, Polycam, CloudCompare |
| **USDZ** | `mesh.usdz`, metadata, anchor map, RAW frames | iOS Quick Look (native), Reality Composer |
| **RAW** | `transforms.json`, `images/`, `depth/`, metadata | Nerfstudio (`ns-process-data`), COLMAP |
| **PLYCM** | `cameras/`, `images/`, `depth/`, `mesh_info.json` | Polycam raw data import |

### Unified Payload Structure
Example output for a standard RAW export:
```
scan4d_scanName_raw_uuid.zip/
├── scan4d_metadata.json  # GPS tags, Location ID, & "export_format"
├── relocalization.worldmap # ARKit spatial anchor for Ghost Overlay rescanning
├── mesh.obj              # Real-time LiDAR wireframe mesh
├── images/               # RGB frames (JPEG, ~2fps adaptive)
│   ├── frame_00000.jpg
│   └── ...
├── depth/                # 16-bit PNG depth maps (millimeters)
│   ├── frame_00000.png
│   └── ...
└── transforms.json       # Camera intrinsics + per-frame 4×4 poses (Nerfstudio-compatible)
```

### Backend Receivers
Scan4D is designed to upload these packages directly to edge/cloud servers. Reference implementors:
- **[wisescan-upload](https://github.com/WiseLabCMU/wisescan-upload):** A simple Python FastAPI receiver that accepts `.zip` PUT requests and saves them. Best for local loopback testing.
- **[wisescan-ingestion](https://github.com/WiseLabCMU/wisescan-ingestion):** The primary production pipeline built on Prefect.io. Automatically routes data to OpenFLAME or COLMAP based on the `scan4d_metadata.json` tags.

## Privacy Filtering

When enabled (toggle on Capture screen):

- **Mesh**: ARKit person segmentation removes human-shaped geometry from the wireframe overlay and exported OBJ
- **Camera Feed**: Detected faces are blurred in real-time with visual indicators
- **RAW Frames**: Faces are Gaussian-blurred in saved JPEG images
- **Depth Maps**: Person regions are zeroed out in 16-bit depth exports

## Quick Start

1. Open the Xcode project in Xcode
2. Set your development team signing in the target settings
3. Build and deploy to a LiDAR-equipped device (iPhone 12 Pro or newer)
4. Configure the upload URL in Settings (gear icon)
5. Go to Capture → tap record → scan → tap stop → name your space to save it
6. In the Workflows tab, tap **Scan Again** under a Location to perform an aligned time-series rescan of that exact space
