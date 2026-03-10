# Changelog

## [0.1.0](https://github.com/WiseLabCMU/wisescan-ios/releases/tag/v0.1.0) (2026-03-10)

Initial release of the Scan4D (WiSEScan) iOS application.

### Features

* **AR Capture**: Real-time LiDAR mesh capture with ARKit, including coverage overlay and live scan stats ([35382b7](https://github.com/WiseLabCMU/wisescan-ios/commit/35382b7))
* **Privacy Filter**: Person segmentation to remove humans from mesh and face blurring for camera frames ([e326796](https://github.com/WiseLabCMU/wisescan-ios/commit/e326796))
* **Export Formats**: Support for OBJ, PLY, USDZ, Polycam RAW, and RAW debug exports ([99ebd93](https://github.com/WiseLabCMU/wisescan-ios/commit/99ebd93), [4ac7406](https://github.com/WiseLabCMU/wisescan-ios/commit/4ac7406))
* **Vertex Coloring**: Color-sampled mesh preview in 3D viewer ([db023f7](https://github.com/WiseLabCMU/wisescan-ios/commit/db023f7))
* **Save & Upload**: Save scans to Files app and upload ZIP bundles to configurable server endpoint ([1c8e5b3](https://github.com/WiseLabCMU/wisescan-ios/commit/1c8e5b3))
* **Scan4D Time-Series**: Anchored time-series relocalization using ARKit ARWorldMaps for repeated scans of the same location ([dfd77af](https://github.com/WiseLabCMU/wisescan-ios/commit/dfd77af))
* **2D Coverage Overlay**: Negative-rendering coverage visualization with convex hull optimization ([1564b0e](https://github.com/WiseLabCMU/wisescan-ios/commit/1564b0e))
* **Data Persistence**: SQLite-backed scan metadata with SwiftData, keep-last-2 retention policy ([5f9613e](https://github.com/WiseLabCMU/wisescan-ios/commit/5f9613e))
* **Persistent Preferences**: Export format and privacy filter selections saved across app launches ([bc4566a](https://github.com/WiseLabCMU/wisescan-ios/commit/bc4566a), [c702f6c](https://github.com/WiseLabCMU/wisescan-ios/commit/c702f6c))

### Bug Fixes

* Repair scan overlay rotation for legacy meshes ([9e0751d](https://github.com/WiseLabCMU/wisescan-ios/commit/9e0751d))
* Fix vertex coloring sampling accuracy ([fa004bd](https://github.com/WiseLabCMU/wisescan-ios/commit/fa004bd))
* Migrate export format metadata to universal format ([0b2bc3d](https://github.com/WiseLabCMU/wisescan-ios/commit/0b2bc3d))
