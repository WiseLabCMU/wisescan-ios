# WiSEScan iOS

`wisescan-ios` is the companion reality capture mobile application for the WiSEScan platform. It acts as an advanced sensor client designed to bridge high-fidelity device data with backend reconstruction servers.

**Requires:** iOS 17.0+ · LiDAR-equipped iPhone or iPad · Xcode 15+

## Features & Implementation Status

| Feature | Description | Status |
| :--- | :--- | :--- |
| **LiDAR Mesh Capture** | Real-time scene reconstruction with live wireframe overlay and quality HUD | ✅ Complete |
| **Start/Stop Recording** | Tap to start scanning with timer, tap again to stop and save | ✅ Complete |
| **Remove Humans** | Person segmentation removes humans from mesh; face detection blurs faces on camera feed and in exports | ✅ Complete |
| **3D Scan Preview** | Interactive SceneKit preview with camera-sampled vertex coloring | ✅ Complete |
| **Export Formats** | OBJ, PLY, USDZ, RAW (Nerfstudio), and Polycam raw data | ✅ Complete |
| **Save to Files** | Export scans locally via iOS share sheet (Files, AirDrop, etc.) | ✅ Complete |
| **Upload to Server** | HTTP PUT upload to configured server URL with status tracking | ✅ Complete |
| **Server Status Check** | HTTP HEAD test on Dashboard shows server reachable/unreachable | ✅ Complete |
| **RAW Data Capture** | RGB frames (JPEG), 16-bit depth maps (PNG), camera poses (transforms.json) | ✅ Complete |
| **Capture Settings** | Upload URL, image overlap maximum, motion blur rejection | ✅ Complete |
| **In-App Guide** | Workflow guide, format descriptions, recommended viewer apps with links | ✅ Complete |
| **LiDAR Check** | Alert on launch if device lacks LiDAR support | ✅ Complete |
| **Server Discovery** | Detect local Prefect orchestration servers via mDNS/Bonjour | 🔲 Planned |
| **Wearable Proxy** | Bridge data from secondary devices (e.g., Meta/Ray-Ban glasses) | 🔲 Planned |
| **Streaming Mode** | Real-time lower-res tracking data sent to server | 🔲 Planned |
| **Workflow Orchestration** | Select preset server pipelines (Mesh, Splat, Spatial Indexing) | 🔲 Planned |
| **Job Observability** | Display remote Prefect job status locally | 🔲 Planned |

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

## Export Formats

| Format | Contents | Viewer |
| :--- | :--- | :--- |
| **OBJ** | Wavefront 3D mesh | MeshLab, Polycam, Blender |
| **PLY** | Polygon file with vertex data | MeshLab, Polycam, CloudCompare |
| **USDZ** | Apple 3D format | iOS Quick Look (native), Reality Composer |
| **RAW** | ZIP: images/ + depth/ + transforms.json | Nerfstudio (`ns-process-data`), COLMAP |
| **PLYCM** | ZIP: images/ + depth/ + cameras/ + mesh_info.json | Polycam raw data import |

### RAW Export Format (Nerfstudio-compatible)

```
scan.zip/
├── images/          # RGB frames (JPEG, ~2fps adaptive)
│   ├── frame_00000.jpg
│   └── ...
├── depth/           # 16-bit PNG depth maps (millimeters)
│   ├── frame_00000.png
│   └── ...
└── transforms.json  # Camera intrinsics + per-frame 4×4 poses
```

### Polycam Export Format

```
scan.zip/
├── images/          # RGB frames (JPEG)
├── depth/           # 16-bit PNG depth maps (millimeters)
├── cameras/         # Per-frame camera JSON (t_00..t_23 pose, fx/fy/cx/cy)
│   ├── frame_00000.json
│   └── ...
├── confidence/      # Confidence maps (reserved)
├── mesh_info.json   # Frame count, image dimensions, coordinate system
└── transforms.json  # Also included for Nerfstudio compatibility
```

## Remove Humans

When enabled (toggle on Capture screen):

- **Mesh**: ARKit person segmentation removes human-shaped geometry from the wireframe overlay and exported OBJ
- **Camera Feed**: Detected faces are blurred in real-time with visual indicators
- **RAW Frames**: Faces are Gaussian-blurred in saved JPEG images
- **Depth Maps**: Person regions are zeroed out in 16-bit depth exports

## Quick Start

1. Open `wisescan-ios.xcodeproj` in Xcode
2. Set your development team signing in the target settings
3. Build and deploy to a LiDAR-equipped device (iPhone 12 Pro or newer)
4. Configure the upload URL in Settings (gear icon)
5. Go to Capture → tap record → scan → tap stop → review on Workflows tab
