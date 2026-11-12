# Scan4D Privacy Policy

*Last updated: November 12, 2026*

## Data Collection

Scan4D does not collect, store, or transmit any personal data to our servers.

All scan data (images, depth maps, meshes, and camera poses) is stored locally on your device. It leaves only when you share a scan (to Files, AirDrop, Mail or another app), or when you set a control plane server and sync a space to it (below).

### Control Plane Sync

If you enter a control plane server in the Server tab, the app keeps that server up to date with the spaces you sync: those you send with Sync to Scan4D Server in a space or Sync on a stitched map, and, depending on the Server tab's Auto sync, every space (All), those you start after the phone joined (New, the default) or none more (Off). Other spaces stay on the phone. Nothing is sent during a scan.

**The map**, on launch and after changes:
- space and scan names and times;
- scan and space IDs;
- each scan's alignment transform and stitch-link anchor poses;
- focus-scan regions (a box);
- whether each scan had Privacy Filtering on (so the lab can see which scans may show people unblurred);
- each room scan's room layout (RoomPlan's walls, floors and objects, as boxes);
- a fingerprint of each processed scan's files, so the server knows which version it holds;
- the device's model, iOS and app version, the device name you enter, and a random device ID the app makes once.

The map holds no images or depth maps.

**Each scan's bundle**, once the scan is processed: everything the scan holds, as one archive. That is its photos (including 360° stills) and depth maps, its mesh with its captured colours, its room layout and the ARKit relocalization map, the same content as a Scan4D export. The privacy filtering below applies to bundles exactly as to exports: with it on, people are pixelated in photos and removed from depth before anything is packed, and a 360° still or focus-scan photo that can't be checked is left out. You choose which bundles go in the Server tab, and they go only over Wi-Fi unless you turn **Upload data bundles only on Wi-Fi** off. Scans are selected by default, except two kinds that wait until you select them: a scan captured with Privacy Filtering off, whose photos show people unblurred, and, if you had **Send map packages** turned off in an earlier version, every scan you had then. Selecting a scan captured with Privacy Filtering off asks you to confirm first.

The server can also ask for a focus scan of a region. The request waits in a to-do list (an urgent one also alerts once), and nothing is captured unless you open it and scan.

If the server has a password, you enter it in the Server tab; it is kept in the device's Keychain and sent only to that server.

Nothing is sent while the server field is empty. The server is the one you configure, normally your lab's own on its internal network.

## Camera & LiDAR

The app uses the rear-facing device camera and LiDAR sensor (when available) for 3D environment scanning. The primary capture mode uses `ARWorldTrackingConfiguration` to reconstruct the physical environment as a 3D mesh.

## Privacy Filtering

Scan4D uses **person segmentation** (not face recognition) to keep people out of captured data. The app does not use the front-facing/TrueDepth camera or `ARFaceTrackingConfiguration`, and collects no facial-geometry, face-mesh, or facial-expression data.

When Privacy Filtering is enabled, the app saves ARKit's person segmentation masks alongside each captured frame during scanning — including the high-resolution still keyframes captured when the device is held still, which follow the same masking path as regular frames. These masks are applied at **export time** — before any data leaves the device, and a sync bundle is built by the same export — to pixelate detected people in RGB images and zero person regions in depth maps. This deferred-blur architecture keeps the real-time capture pipeline lightweight (preventing VIO tracking loss from encode backpressure) while maintaining the same privacy guarantee: no unblurred image or unmasked depth map is ever exported or uploaded.

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

Because a switch left off by mistake would keep capturing everyone in later scans, the choice expires: switched off, Privacy Filtering turns itself back on 24 hours later (checked when the capture screen opens, when the app returns to the foreground and when a scan is about to start, never during a scan; a scan about to start with an expired choice does not start until the operator has seen the filter is back on). The capture screen's warning stays readable while recording, and says when the filter will turn back on.

## Location Data

Location data (GPS coordinates) is captured only when Location permissions are granted and is embedded in scan metadata for spatial alignment purposes. This data is never sent to third parties.

## Third-Party Services

Scan4D does not integrate any third-party analytics, advertising, or tracking SDKs.

## Data Retention

Scan data persists on your device until you manually delete it from within the app. No data is retained on any remote server unless you set a control plane server and sync spaces to it, which keeps their map and the bundles above. Deleting a scan on the device marks it gone there rather than erasing its record or its bundle.

## Contact

For questions about this privacy policy, contact: **arenaxr@andrew.cmu.edu**
