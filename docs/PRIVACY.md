# Scan4D Privacy Policy

*Last updated: April 30, 2026*

## Data Collection

Scan4D does not collect, store, or transmit any personal data to our servers.

All scan data (images, depth maps, meshes, and camera poses) is stored locally on your device and is only uploaded when you explicitly configure a server URL and tap the Upload button.

## Camera & LiDAR

The app uses the rear-facing device camera and LiDAR sensor (when available) for 3D environment scanning. The primary capture mode uses `ARWorldTrackingConfiguration` to reconstruct the physical environment as a 3D mesh.

## Privacy Filtering

Scan4D uses **person segmentation** (not face recognition) to keep people out of captured data. The app does not use the front-facing/TrueDepth camera or `ARFaceTrackingConfiguration`, and collects no facial-geometry, face-mesh, or facial-expression data.

When Privacy Filtering is enabled, the app saves ARKit's person segmentation masks alongside each captured frame during scanning — including the high-resolution still keyframes captured when the device is held still, which follow the same masking path as regular frames. These masks are applied at **export time** — before any data leaves the device — to pixelate detected people in RGB images and zero person regions in depth maps. This deferred-blur architecture keeps the real-time capture pipeline lightweight (preventing VIO tracking loss from encode backpressure) while maintaining the same privacy guarantee: no unblurred image or unmasked depth map is ever exported or uploaded.

Raw (unblurred) images exist temporarily in the app's sandboxed container between capture and export. They are not accessible to other apps and are only exported after privacy blur is applied. The segmentation masks themselves are internal-only and are not included in any export archive.

Person-shaped geometry is also excluded from the exported mesh, and a live on-screen indicator shows detected people during scanning. All privacy processing occurs entirely on-device.

## Location Data

Location data (GPS coordinates) is captured only when Location permissions are granted and is embedded in scan metadata for spatial alignment purposes. This data is never sent to third parties.

## Third-Party Services

Scan4D does not integrate any third-party analytics, advertising, or tracking SDKs.

## Data Retention

Scan data persists on your device until you manually delete it from within the app. No data is retained on any remote server unless you explicitly upload it to a server you configure.

## Contact

For questions about this privacy policy, contact: **arenaxr@andrew.cmu.edu**
