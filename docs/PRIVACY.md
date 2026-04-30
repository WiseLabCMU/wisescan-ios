# Scan4D Privacy Policy

*Last updated: April 30, 2026*

## Data Collection

Scan4D does not collect, store, or transmit any personal data to our servers.

All scan data (images, depth maps, meshes, and camera poses) is stored locally on your device and is only uploaded when you explicitly configure a server URL and tap the Upload button.

## Camera & LiDAR

The app uses the rear-facing device camera and LiDAR sensor (when available) for 3D environment scanning. The primary capture mode uses `ARWorldTrackingConfiguration` to reconstruct the physical environment as a 3D mesh.

## TrueDepth API & Face Data

Scan4D includes a Developer Mode feature that allows switching to the front-facing (TrueDepth) camera using `ARFaceTrackingConfiguration`. This feature is intended solely for testing the app's privacy filtering pipeline (face blurring and person segmentation) during development.

**What is collected:** When the front-camera mode is activated, the TrueDepth camera provides a live camera feed and face geometry data via ARKit's `ARFaceTrackingConfiguration`. This data is used to render a camera preview on-screen and to test the privacy filter's face detection accuracy.

**How it is used:** The TrueDepth data is used exclusively for real-time, on-device rendering and privacy filter validation. No face geometry, face mesh, facial expression, or face-related data is saved to disk, written to any file, transmitted over any network, or included in any scan export.

**Data sharing:** No TrueDepth or face data is shared with any third party. The data exists only in volatile memory during the active AR session and is discarded when the user switches back to the rear camera or leaves the Capture screen.

**Data retention:** Face data from the TrueDepth API is never persisted. It is held in memory only for the duration of the front-camera session and is released immediately when the session ends.

## Privacy Filtering

When Privacy Filtering is enabled, detected faces are blurred locally using Apple's Vision framework, and person regions are removed from exported mesh data using ARKit's person segmentation. All privacy processing occurs entirely on-device before any data is saved or uploaded.

## Location Data

Location data (GPS coordinates) is captured only when Location permissions are granted and is embedded in scan metadata for spatial alignment purposes. This data is never sent to third parties.

## Third-Party Services

Scan4D does not integrate any third-party analytics, advertising, or tracking SDKs.

## Data Retention

Scan data persists on your device until you manually delete it from within the app. No data is retained on any remote server unless you explicitly upload it to a server you configure.

## Contact

For questions about this privacy policy, contact: **arenaxr@andrew.cmu.edu**
