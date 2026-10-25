# Scan4D Privacy Policy

*Last updated: October 25, 2026*

## Data Collection

Scan4D does not collect, store, or transmit any personal data to our servers.

All scan data (images, depth maps, meshes, and camera poses) is stored locally on your device and is only uploaded when you explicitly configure a server URL and tap the Upload button.

### Control Plane Sync

If you enter a control plane server in Settings → Control plane, the app keeps that server up to date with an inventory of this device's scans. It sends this on launch and after changes, and never during a scan. The inventory holds:
- space and scan names and times;
- scan and space IDs;
- each scan's alignment transform and stitch-link anchor poses;
- focus-scan regions (a box);
- upload state;
- the device's model, iOS and app version, the device name you enter, and a random device ID the app makes once.

The inventory holds no images or depth maps.

With **Send map packages** on (the default), the app also uploads the files the server asks for:
- each room scan's mesh (with its captured vertex colours, people already removed at capture), room layout, alignment, and ARKit relocalization map;
- its sparse feature-point cloud and, where recorded, its sweep-coverage grid (points and cells, not images);
- each focus scan's box.

Photos and depth maps leave only through an export you start. With a control plane set, the export's destination comes from it: a one-time upload address for the lab's own storage, so no storage credentials are kept on the phone. The privacy filtering above applies to these exports as to any other.

The server can also ask for a focus scan of a region. The app shows the request, and nothing is captured unless you open it and scan.

Nothing is sent while the server field is empty. The server is the one you configure, normally your lab's own on its internal network.

## Camera & LiDAR

The app uses the rear-facing device camera and LiDAR sensor (when available) for 3D environment scanning. The primary capture mode uses `ARWorldTrackingConfiguration` to reconstruct the physical environment as a 3D mesh.

## Privacy Filtering

Scan4D uses **person segmentation** (not face recognition) to keep people out of captured data. The app does not use the front-facing/TrueDepth camera or `ARFaceTrackingConfiguration`, and collects no facial-geometry, face-mesh, or facial-expression data.

When Privacy Filtering is enabled, the app saves ARKit's person segmentation masks alongside each captured frame during scanning — including the high-resolution still keyframes captured when the device is held still, which follow the same masking path as regular frames. These masks are applied at **export time** — before any data leaves the device — to pixelate detected people in RGB images and zero person regions in depth maps. This deferred-blur architecture keeps the real-time capture pipeline lightweight (preventing VIO tracking loss from encode backpressure) while maintaining the same privacy guarantee: no unblurred image or unmasked depth map is ever exported or uploaded.

Raw (unblurred) images exist temporarily in the app's sandboxed container between capture and export. They are not accessible to other apps and are only exported after privacy blur is applied. The segmentation masks themselves are internal-only and are not included in any export archive.

Person-shaped geometry is also excluded from the exported mesh, and a live on-screen indicator shows detected people during scanning. Mesh exports carry per-vertex colors sampled from the captured frames; with Privacy Filtering on, that sampling skips the same person masks (with a margin around each person), and skips any frame whose mask is missing, so no person's appearance is baked into the mesh colors. All privacy processing occurs entirely on-device.

### Focus Scan Stills

A focus scan (photos of one region) captures full-resolution stills without running ARKit's person
segmentation during capture. When Privacy Filtering is enabled, every still receives a person check
at export time instead: Vision's person segmentation runs on an upright copy of the still, detected
person regions are pixelated on the full-resolution image, and the same regions are zeroed in its
depth map. The check fails closed: a still that cannot be verified or blurred is left out of the
export (with its depth and confidence), and the export lists it in `privacy_excluded.json`. A still
with no person detected ships unchanged. Because nothing is filtered while capturing, the toggle stays
live during a focus scan, and the scan records it as it stands when the scan stops (a change made
mid-capture is noted in its `events.log`).

### 360° Camera Stills

When an external 360° camera (e.g. Ricoh Theta) is connected, its equirectangular stills capture everyone around the operator — including people who never appeared in the phone's viewfinder. When Privacy Filtering is enabled, each still receives a person-privacy pass at export time: it is resampled into perspective cube faces, person segmentation runs per face, and detected person regions are pixelated on the full-resolution image before it is included in any export. A still that cannot be verified is excluded from the export entirely — with the filter on, raw 360° imagery never leaves the device.

Disabling Privacy Filtering is an explicit, per-scan choice — supporting captures where people are the subject (for example a posed group-photo 3D model). The capture screen warns that people in view will be captured unblurred and that a 360° camera captures every direction, including behind the operator; the setting is locked for the duration of each room scan (a focus scan takes its value at Stop, see above); and each scan's privacy state is recorded in its export metadata (`privacy_filter`) so downstream processing can honor it.

## Location Data

Location data (GPS coordinates) is captured only when Location permissions are granted and is embedded in scan metadata for spatial alignment purposes. This data is never sent to third parties.

## Third-Party Services

Scan4D does not integrate any third-party analytics, advertising, or tracking SDKs.

## Data Retention

Scan data persists on your device until you manually delete it from within the app. No data is retained on any remote server unless you explicitly upload it to a server you configure, or set a control plane server, which keeps the inventory above. Deleting a scan on the device marks it gone there rather than erasing its record.

## Contact

For questions about this privacy policy, contact: **arenaxr@andrew.cmu.edu**
