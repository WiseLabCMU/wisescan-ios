# Scan4D — App Store Connect Listing

> Copy-paste ready content for promoting from TestFlight to the App Store.

---

## App Name

```
Scan4D
```

## Subtitle (30 chars max)

```
Time-Series Reality Capture
```

---

## Promotional Text (170 chars max)

> This text appears above your description and can be updated without a new build.

```
Capture, re-scan, and export high-fidelity 3D scans with LiDAR depth, RGB, and camera poses — all from your iPhone or iPad.
```

---

## Description (4000 chars max)

```
Scan4D is a professional-grade reality capture app for iPhone and iPad. It turns your device's LiDAR sensor and camera into a powerful 3D scanner, capturing detailed meshes, depth maps, and camera poses for downstream reconstruction, photogrammetry, and spatial computing.

• AR mode: real-time mesh with procedural wireframe overlay and 3D occlusion-based coverage visualization
• VR mode: live accumulated depth point cloud with bloom and confidence decay on a dark background
• 16-bit depth maps with confidence maps captured at adaptive frame rates
• Scan capacity metrics: polygon count, drift tracking, session duration
• Interactive 3D mesh preview with camera-sampled vertex coloring and loading indicator
• Privacy filtering: person segmentation removes humans from meshes, face blurring in RGB exports
• VIO tracking guard: automatic halt and save prompt on mid-scan tracking loss

PROXY MODE (Meta Ray-Ban Smart Glasses)
• Stream frames from Meta Ray-Ban glasses via Bluetooth
• Picture-in-picture preview on capture screen
• Privacy filter applied to wearable frames
• Configurable FPS slider for stream quality

TIME-SERIES SCANNING
• Group scans by Location and re-scan the same space over time
• Rescan Space and Link Adjacent Space load a configurable ghost-mesh overlay of previous captures
• Adjacent stitching: scan neighboring areas with shared coordinate frames
• ARWorldMap relocalization with rejection and manual ghost mesh alignment
• Linked-scan graph visualization with combined-mesh viewer
• Tracking instruction banners guide you through scanning and relocalization

BULK OPERATIONS
• Multi-select locations for bulk delete
• Multi-select scans for bulk Save, Upload, and Delete
• Background post-scan processing with per-card progress

FLEXIBLE EXPORT FORMATS
• Scan4D: Full bundle with metadata, relocalization map, images, depth, confidence, and camera data
• Polycam: Raw data import compatible with Polycam
• RAW: Nerfstudio/COLMAP-compatible transforms.json + images + depth
• OBJ / PLY / USDZ: Native mesh formats for MeshLab, Blender, and iOS Quick Look

SERVER INTEGRATION
• Configure any HTTP(S) upload endpoint in Settings
• Direct PUT upload with live progress tracking
• Save to Files or AirDrop for offline workflows
• Compatible with self-hosted reconstruction pipelines

DEVELOPER MODE
• Synthetic IMU, camera, and depth injection for Simulator testing
• Performance diagnostics and debug overlays
• Mock wearables mode for testing glasses integration

Designed for researchers, 3D scanning professionals, and spatial computing developers who need raw, high-fidelity sensor data with full control over the reconstruction pipeline.

Requires a LiDAR-equipped iPhone or iPad Pro. Meta Ray-Ban Smart Glasses supported for proxy frame capture.
```

---

## What's New (version 0.3.0)

```
• Meta Ray-Ban Smart Glasses: stream, capture, and privacy-filter wearable frames via Bluetooth
• VR capture mode: live accumulated point cloud with bloom effects and confidence decay
• AR coverage overlay: 3D occlusion-based visualization shows scanned vs. unscanned areas
• Procedural wireframe: replaced depth rainbow with a color-controlled wireframe shader
• Tracking safety: VIO starvation guard halts the scan and prompts save on tracking loss
• Relocalization rejection and manual ghost mesh alignment for rescan/stitch workflows
• Linked-scan graph and combined-mesh viewer for adjacent-space stitching
• Bulk operations: multi-select locations and scans for Save, Upload, and Delete
• Depth confidence map export alongside depth frames
• Tracking instruction banners guide initial scanning and relocalization
• Use case picker when naming a scan (Rescan Space or Link Adjacent Space)
• Settings access button added directly to the capture view
• Live percentage indicator for photo-based vertex coloring progress
• Mesh preview loading indicator while geometry loads
• Extensive performance optimizations: faster stop, lower memory, throttled UI updates
• Numerous bug fixes for AR session lifecycle, privacy filtering, and stitching stability
```

---

## Keywords (100 chars max, comma-separated)

```
3D scanner,LiDAR,reality capture,photogrammetry,depth map,mesh,point cloud,ARKit,spatial,wearable
```

---

## Categories

| Field | Value |
|-------|-------|
| **Primary Category** | Utilities |
| **Secondary Category** | Productivity |

---

## Age Rating

| Question | Answer |
|----------|--------|
| Contains unrestricted web access? | No |
| Contains gambling or contests? | No |
| Contains mature/suggestive themes? | No |
| Contains profanity or crude humor? | No |
| Contains medical information? | No |
| Contains horror/fear themes? | No |
| Contains violence? | No |
| Contains alcohol, tobacco, drugs? | No |

**Recommended Rating:** 4+

---

## Support URL


```
https://github.com/WiseLabCMU/wisescan-ios
```

---

## Privacy Policy URL

```
https://github.com/WiseLabCMU/wisescan-ios/blob/main/docs/PRIVACY.md
```

---

## Screenshots

> [!NOTE]
> You need **at least 3 screenshots** for each device size class (6.7" iPhone, 6.1" iPhone, and iPad if supported). Recommended: 5-8 screenshots.

### Suggested Screenshot Sequence

| # | Screen | Caption |
|---|--------|---------|
| 1 | **AR Capture View** (recording active, wireframe visible) | "Real-time LiDAR mesh capture with procedural wireframe overlay" |
| 2 | **VR Capture View** (point cloud on black background) | "Accumulated depth point cloud with bloom and confidence decay" |
| 3 | **Capture View** (privacy filter on, red-eye markers) | "Built-in privacy filtering with person detection and face blurring" |
| 4 | **3D Mesh Preview** (colored mesh in SceneKit viewer) | "Interactive 3D preview with camera-sampled vertex coloring" |
| 5 | **Scans List** (location grid with multi-select active) | "Organize scans by location with bulk Save, Upload, and Delete" |
| 6 | **Link Adjacent Space** (ghost overlay + tracking banner) | "Re-scan over time or link adjacent areas with guided alignment" |
| 7 | **Meta Ray-Ban PiP** (glasses stream + capture view) | "Stream frames from Meta Ray-Ban Smart Glasses via Bluetooth" |
| 8 | **Export Format Picker** (scan card with format dropdown) | "Export to Scan4D, Polycam, Nerfstudio, OBJ, PLY, or USDZ" |
| 9 | **Dashboard** (server status + glasses connection) | "Connect to your server and pair Meta Ray-Ban Smart Glasses" |
| 10 | **Settings** (upload URL + capture mode + glasses) | "Full control over capture quality, mode, and device pairing" |

---

## App Store Icon

> Already set via `AppIcon` in `Assets.xcassets`. Ensure it meets the 1024×1024 requirement with no transparency.

---
