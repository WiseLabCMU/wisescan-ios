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

FULL MODE (LiDAR devices)
• Real-time mesh reconstruction with live wireframe overlay
• 16-bit depth maps captured at adaptive frame rates
• Scan capacity metrics: polygon count, drift tracking, session duration
• Interactive 3D mesh preview with camera-sampled vertex coloring
• Privacy filtering: person segmentation removes humans from meshes, face blurring in RGB exports

LITE MODE (all devices)
• RGB frame capture with ARKit camera poses
• Server-side photogrammetry via exported image bundles
• Automatic detection — no configuration needed

TIME-SERIES SCANNING
• Group scans by Location and re-scan the same space over time
• "Extend Scan" loads a red ghost-mesh overlay of previous captures
• Adjacent stitching: scan neighboring areas with shared coordinate frames
• ARWorldMap relocalization for precise alignment between sessions

FLEXIBLE EXPORT FORMATS
• Scan4D: Full bundle with metadata, relocalization map, images, depth, and camera data
• Polycam: Raw data import compatible with Polycam
• RAW: Nerfstudio/COLMAP-compatible transforms.json + images + depth
• OBJ / PLY / USDZ: Native mesh formats for MeshLab, Blender, and iOS Quick Look

SERVER INTEGRATION
• Configure any HTTP(S) upload endpoint in Settings
• Direct PUT upload with live progress tracking
• Save to Files or AirDrop for offline workflows
• Compatible with self-hosted reconstruction pipelines

DEVELOPER MODE
• Front/back camera switching for testing privacy features
• Synthetic IMU, camera, and depth injection for Simulator testing
• Vertex mapping diagnostics and debug overlays

Designed for researchers, 3D scanning professionals, and spatial computing developers who need raw, high-fidelity sensor data with full control over the reconstruction pipeline.

Requires ARKit-capable device. LiDAR-equipped iPhone or iPad Pro recommended for full functionality.
```

---

## What's New (version 0.2.1)

```
• Upload server URL is now user-configurable (no hardcoded defaults)
• Upload button disabled when no server is configured
• Dashboard skips auto connection test for unconfigured servers
• Fixed Info.plist encryption compliance key
• Internal queue and identifier updates for Scan4D branding
```

---

## Keywords (100 chars max, comma-separated)

```
3D scanner,LiDAR,reality capture,photogrammetry,depth map,mesh,point cloud,ARKit,spatial,research
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

> [!IMPORTANT]
> You need a live URL here. Options:
> - GitHub repo README: `https://github.com/WiseLabCMU/wisescan-ios`
> - WiseLab website: `https://wise.ece.cmu.edu/` (if applicable)
> - A dedicated support page

```
https://github.com/WiseLabCMU/wisescan-ios
```

---

## Privacy Policy URL

> [!IMPORTANT]
> **Required for all App Store submissions.** Host [PRIVACY.md](PRIVACY.md) at a public URL and link it here.
> For example: `https://github.com/WiseLabCMU/wisescan-ios/blob/main/docs/PRIVACY.md`

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
| 1 | **Capture View** (recording active, wireframe visible) | "Real-time LiDAR mesh capture with live wireframe overlay" |
| 2 | **Capture View** (privacy filter on, face blur visible) | "Built-in privacy filtering with face detection and person removal" |
| 3 | **3D Mesh Preview** (colored mesh in SceneKit viewer) | "Interactive 3D preview with camera-sampled vertex coloring" |
| 4 | **Scans List** (location grid with thumbnails) | "Organize scans by location for time-series and spatial mapping" |
| 5 | **Extend Scan** (red ghost overlay visible) | "Re-scan spaces over time or extend into adjacent areas" |
| 6 | **Export Format Picker** (scan card with format dropdown) | "Export to Scan4D, Polycam, Nerfstudio, OBJ, PLY, or USDZ" |
| 7 | **Dashboard** (server status card) | "Connect to your own reconstruction server" |
| 8 | **Settings** (upload URL + capture settings) | "Full control over capture quality and server configuration" |

---

## App Store Icon

> Already set via `AppIcon` in `Assets.xcassets`. Ensure it meets the 1024×1024 requirement with no transparency.

---

## Checklist Before Submit

- [ ] Privacy Policy URL is live and accessible
- [ ] Support URL is live and accessible
- [ ] At least 3 screenshots per device class uploaded
- [ ] App description reviewed for accuracy
- [ ] Age rating questionnaire completed
- [ ] Build `0.2.1 (3)` selected in the Version section
- [ ] Export compliance (encryption) set to NO ✅ (already in Info.plist)
