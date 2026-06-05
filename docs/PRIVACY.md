# Scan4D Privacy Policy

*Last updated: April 30, 2026*

## Data Collection

Scan4D does not collect, store, or transmit any personal data to our servers.

All scan data (images, depth maps, meshes, and camera poses) is stored locally on your device and is only uploaded when you explicitly configure a server URL and tap the Upload button.

## Camera & LiDAR

The app uses the rear-facing device camera and LiDAR sensor (when available) for 3D environment scanning. The primary capture mode uses `ARWorldTrackingConfiguration` to reconstruct the physical environment as a 3D mesh.

## Privacy Filtering

Scan4D uses **person segmentation** (not face recognition) to keep people out of captured data. The app does not use the front-facing/TrueDepth camera or `ARFaceTrackingConfiguration`, and collects no facial-geometry, face-mesh, or facial-expression data.

When Privacy Filtering is enabled, detected people are pixelated locally — driven by ARKit's `.personSegmentationWithDepth` stencil, with an on-device Apple Vision person-segmentation fallback if the stencil is unavailable — across the live indicator, the saved RGB frames, and (zeroed) the exported depth maps; person-shaped geometry is also excluded from the exported mesh. All privacy processing occurs entirely on-device before any data is saved or uploaded.

## Location Data

Location data (GPS coordinates) is captured only when Location permissions are granted and is embedded in scan metadata for spatial alignment purposes. This data is never sent to third parties.

## Third-Party Services

Scan4D does not integrate any third-party analytics, advertising, or tracking SDKs.

## Data Retention

Scan data persists on your device until you manually delete it from within the app. No data is retained on any remote server unless you explicitly upload it to a server you configure.

## Contact

For questions about this privacy policy, contact: **arenaxr@andrew.cmu.edu**
