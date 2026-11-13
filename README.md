# Scan4D

Scan4D is the iPhone and iPad capture app for the WiSEScan platform. It records spaces over time (photos, camera poses, LiDAR depth and mesh) and syncs them to a Scan4D server for reconstruction.

**Requires:** iOS 18.0+ on an ARKit-capable iPhone or iPad; building needs Xcode 26.6+ ([docs/BUILDING.md](docs/BUILDING.md))  
**Recommended:** a LiDAR device (iPhone Pro or iPad Pro) for mesh and depth capture  
**Optional:** a rig-mounted Ricoh Theta X or Z1 as a 360° still source

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
| **Server Reconstruction** | Gaussian splat (`scan4d-splat`) | Planned (test harness today) | Planned (test harness today) |

## Features

Each feature links to its entry in [REQUIREMENTS.md](REQUIREMENTS.md), which has the full behavior and design.

### Capture

- **AR and VR views:** AR shows the camera feed with a live wireframe of the mesh, and VR shows a live depth point cloud on black. Switch between them in Settings. ([REQ-025](REQUIREMENTS.md#req-025-vr-capture-mode))
- **LiDAR mesh capture:** The mesh builds in real time, with a capacity HUD that warns before ARKit's session limits. A coach bar gives scanning tips as you go. ([REQ-001](REQUIREMENTS.md#req-001-lidar-mesh-capture), [REQ-014](REQUIREMENTS.md#req-014-scan-capacity-metrics), [REQ-029](REQUIREMENTS.md#req-029-scan-coaching))
- **Space staging analyzer:** Before you scan a new space, an optional 360° sweep checks the lighting and looks for screens, doors and people. A report lists what to fix. ([REQ-030](REQUIREMENTS.md#req-030-space-staging-analyzer))
- **Automatic room photos:** A room scan takes sharp 12MP stills by itself whenever the device is steady and the view has changed. An amber overlay marks surfaces that have depth but no photo yet. ([REQ-036](REQUIREMENTS.md#req-036-room-scan-automatic-stills), [REQ-031](REQUIREMENTS.md#req-031-capture-quality-hi-res-stillness-keyframes))
- **Focus scan:** Rescan one region instead of the whole room by drawing a box on the previous scan's mesh and walking around it while the app takes photos. A region can also come from a deep link, a file, or a server request. ([REQ-035](REQUIREMENTS.md#req-035-focus-scan-partial-scan-of-one-region), [REQ-037](REQUIREMENTS.md#req-037-focus-region-import-deep-link--file))
- **360° still source:** A rig-mounted Ricoh Theta connects over Bluetooth and Wi-Fi and takes a full-sphere still alongside the phone's photos. Each still's pose is solved against the scan's mesh when the scan is processed. ([REQ-033](REQUIREMENTS.md#req-033-360-still-source-ricoh-theta))
- **Privacy filtering:** People are pixelated in saved photos and removed from depth maps and the mesh, with a live marker on screen. The filter is on by default and turns itself back on 24 hours after it is switched off. ([REQ-004](REQUIREMENTS.md#req-004-privacy-filtering), [docs/PRIVACY.md](docs/PRIVACY.md))
- **Lite mode:** Devices without LiDAR capture photos and camera poses only. It is a test harness in local debug builds; TestFlight and App Store builds require LiDAR. ([REQ-001b](REQUIREMENTS.md#req-001b-lite-mode-no-lidar))

### Rescan and link

- **Rescan and Link Adjacent:** Each location's scans are either Rescans (the same area later) or Link Adjacent scans (the neighboring area). Both line up with the previous scan through a ghost overlay, and Pin & Extend links the next room mid-scan. ([REQ-003](REQUIREMENTS.md#req-003-scan4d-rescan--link-adjacent--temporal--spatial-capture))
- **Linked-scan graph:** The Scans tab shows linked scans as a node graph and can display them together as one combined mesh. Each link is saved in `stitching.json` and travels with every export. ([REQ-012](REQUIREMENTS.md#req-012-map-stitching-and-coverage))

### Process

- **Process and Color:** After a save, processing aligns each rescan into its location's shared coordinate frame and builds the ghost that later rescans line up with. The scan card's **Color** button paints the mesh from the scan's photos. ([REQ-032](REQUIREMENTS.md#req-032-post-save-processing--plane-registration-canonical-frame))
- **Levels and ramps:** Processing recovers the steps, landings and ramps that RoomPlan leaves out. It also keeps curved walls from being flattened to a straight plane. ([REQ-034](REQUIREMENTS.md#req-034-derived-levels--ramps-multi-level-ghost-proxy))
- **Coverage and feature files:** Each scan records where the LiDAR sweep looked (`sweep_coverage.bin`) and ARKit's sparse feature points (`arkit_features.bin`). Feature ids carry across scans of a location, so successive scans can be compared for changes. ([REQ-039](REQUIREMENTS.md#req-039-sweep-coverage-export), [REQ-040](REQUIREMENTS.md#req-040-feature-point-cloud-export))

### Share and sync

- **Share:** Send a scan to Files, AirDrop or Mail as a Scan4D bundle or as a mesh file (OBJ, PLY or USDZ). You pick the format each time. ([REQ-007](REQUIREMENTS.md#req-007-share--sync))
- **Scan4D server sync:** Set a server in the Server tab and the app keeps it up to date with the spaces you choose, sending each processed scan whole in the background. The server can send back join fine-tunes and requests for focus scans. ([REQ-038](REQUIREMENTS.md#req-038-control-plane-sync-device-registry--inventory))

### Developer

- **Developer Mode:** A Settings toggle adds Simulator data injection, performance diagnostics, capture tuning and a 360° camera bench. [docs/developer-tools.md](docs/developer-tools.md) describes each tool. ([REQ-013](REQUIREMENTS.md#req-013-developer-mode))

See also: [CHANGELOG.md](CHANGELOG.md) · [docs/BUILDING.md](docs/BUILDING.md) · [docs/RELEASE.md](docs/RELEASE.md) · [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) · [docs/SCAN_GUIDANCE.md](docs/SCAN_GUIDANCE.md)

## Architecture

The app's sources are in [scan4d-ios/](scan4d-ios/). REQUIREMENTS.md has the [architecture diagrams](REQUIREMENTS.md#ios-app-architecture) and a [Source File Index](REQUIREMENTS.md#source-file-index) that lists every file by area.

## Export Formats

The app has one capture export, **Scan4D**, and three single-file mesh exports, named
`scan4d_{locationName}_{scanName}_{format}_{timestamp}_{uuid}.{ext}`.

| Format | Extension | Contents | Viewer |
| :--- | :--- | :--- | :--- |
| **Scan4D** | `.zip` | Everything the scan captured: photos, depth, camera poses, the colored mesh, the RoomPlan layout, registration, links and coverage files, plus 360° stills from a rig | The Scan4D server |
| **OBJ** | `.obj` | Mesh with captured vertex colors | MeshLab, Blender |
| **PLY** | `.ply` | Mesh with captured vertex colors | MeshLab, CloudCompare |
| **USDZ** | `.usdz` | Mesh with captured vertex colors | iOS Quick Look |

The Scan4D server makes Nerfstudio and flame3d datasets from a Scan4D export. [schemas/README.md](schemas/README.md) documents every file in the bundle.

## Backend

Scan4D syncs to the lab's stack ([REQ-038](REQUIREMENTS.md#req-038-control-plane-sync-device-registry--inventory)):

- **`scan4d-server`** (private): the control plane, with the device registry, the inventory of spaces and scans, each scan's synced bundle, focus-scan requests and a web 3D map view.
- **`scan4d-flows`** (private): the Prefect flows the server runs, such as `scan4d-splat` (a scan to a Gaussian splat) and `scan4d-convert` (Nerfstudio and flame3d datasets).
- **[wisescan-upload](https://github.com/WiseLabCMU/wisescan-upload):** the upload gateway earlier builds sent exports to. The app no longer uses it.
- **[wisescan-ingestion](https://github.com/WiseLabCMU/wisescan-ingestion):** a NATS JetStream stack for time-series streams, not on the export path. It is the candidate receiver for a future streaming mode (REQ-018).

## Quick Start

1. Open `scan4d-ios.xcodeproj` in Xcode, set your signing team, and run on an ARKit-capable device (LiDAR recommended).
2. *(Optional)* Enter your Scan4D server in the Server tab to sync spaces to it.
3. *(Optional 360°)* On the Dashboard, tap **Add Ricoh Theta 360° Camera**, pick the camera from the Bluetooth list, and confirm the pairing code once. After that, **Connect** wakes and joins it.
4. In Capture, tap record, scan the room, then tap stop and choose **Save & End** (or **Save & Scan Adjacent** to go on into the next room).
5. Name the space and choose **Rescan** (the same space over time) or **Link Adjacent** (a neighboring space). Processing runs on its own; tap **Color** on the scan card to color the mesh.
6. Later, continue a location from the Scans tab with **Rescan Space** or **Link Adjacent Space**, lining up with the ghost of the previous scan.

Meta Ray-Ban glasses need extra developer setup: see [Meta Wearables setup](docs/BUILDING.md#meta-wearables-setup) in docs/BUILDING.md.

## License

This project is licensed under the BSD 3-Clause License - see the [LICENSE](LICENSE) file for details.
