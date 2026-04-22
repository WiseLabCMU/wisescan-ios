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

## Features

- **LiDAR Mesh Capture:** Real-time scene reconstruction with live wireframe overlay and quality HUD (LiDAR devices only).
- **Lite Mode:** Non-LiDAR devices capture images + camera poses for server-side photogrammetry. A persistent banner indicates lite mode.
- **Scan4D (Extend Scan):** Group scans by Location. Use "Extend Scan" with a red ghost-mesh overlay to either re-scan the same space for time-series updates, or move to the edge and scan adjacent areas for downstream stitching.
- **Privacy Filtering:** Person segmentation removes human geometry from the localized mesh; face detection blurs faces on camera feeds and natively generates unprojected 3D red-alert markers indicating downstream face removal on your mesh preview.
- **Scan Capacity Metrics:** Live polygon count, anchor count, drift tracking, and session duration with a composite capacity indicator that warns users when approaching ARKit session limits.
- **Developer Mode:** Toggleable debugging tools including front/back camera switching for testing privacy features, with a persistent banner across all views.
- **Export & Scan Capture Data:** Export native mesh formats (OBJ, PLY, USDZ) along with RAW RGB, depth, and camera poses governed by motion-blur rejection and overlapping metrics.
- **Server Integration:** Direct HTTP upload to configured server URLs for edge or cloud reconstruction orchestration.

> **Note:** For a comprehensive list of all features, architecture diagrams, and detailed implementation status, please see [REQUIREMENTS.md](REQUIREMENTS.md).
>
> See also: **[CHANGELOG.md](CHANGELOG.md)** · **[RELEASE.md](RELEASE.md)**

## Architecture

```
wisescan-ios/
├── AppDelegate.swift          # App lifecycle, splash screen
├── ContentView.swift          # Tab bar (Dashboard, Capture, Workflows) + LiDAR check + Developer Mode banner
├── DashboardView.swift        # Upload server status card, wearable glasses connect
├── CaptureView.swift          # Live capture UI, recording controls, scan HUD, capacity metrics, flip camera
├── ARCoverageView.swift       # ARKit scene reconstruction, person segmentation, OBJ export, capacity tracking
├── FaceBlurOverlay.swift      # Live face detection overlay + face blur utility for exports
├── FrameCaptureSession.swift  # RAW data capture (RGB, depth, poses → transforms.json + Polycam cameras/)
├── ScansListView.swift        # Scan cards, location rename, format picker, save/upload actions
├── MeshPreviewView.swift      # SceneKit 3D mesh preview with camera-sampled or height-gradient coloring
├── ScanStore.swift            # Shared data models (CapturedScan, ExportFormat, ScanStats, capacity scoring)
└── SettingsView.swift         # Upload URL, RAW export settings, Developer Mode toggles, workflow guide
```

## Export Formats & Backend Ingestion

Each export format includes **only** the data relevant to that format. The filename convention is:
`scan4d_{locationName}_{scanName}_{format}_{timestamp}_{uuid}.{ext}`

| Format | Extension | Contents | Viewer |
| :--- | :--- | :--- | :--- |
| **Scan4D** | `.zip` | `scan4d_metadata.json`, `relocalization.worldmap`, + full Polycam payload | Scan4D server workflows |
| **Polycam** | `.zip` | `images/`, `depth/`, `cameras/`, `mesh_info.json` | Polycam raw data import |
| **RAW** | `.zip` | `images/`, `depth/`, `transforms.json` | Nerfstudio, COLMAP |
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
- **Camera Feed**: Detected faces are blurred in real-time with visual indicators
- **RAW Frames**: Faces are Gaussian-blurred in saved JPEG images
- **Depth Maps**: Person regions are zeroed out in 16-bit depth exports

## Quick Start

1. Open the Xcode project in Xcode
2. Set your development team signing in the target settings
3. Build and deploy to a LiDAR-equipped device (iPhone 12 Pro or newer)
4. Configure the upload URL in Settings (gear icon)
5. Go to Capture → tap record → scan → tap stop → name your space to save it
6. In the Scans tab, tap **Extend Scan** on any scan card to either re-scan the same space (time-series) or scan adjacent areas (stitching). The red overlay shows the previous scan boundary.

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
