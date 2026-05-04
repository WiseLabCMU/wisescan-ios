# Changelog

## [0.3.0](https://github.com/WiseLabCMU/wisescan-ios/compare/v0.2.1...v0.3.0) (2026-05-04)


### Features

* **confidence:** support depth confidenceMap export ([14c944b](https://github.com/WiseLabCMU/wisescan-ios/commit/14c944b2a12e50082003b01cdcaee4a178b8a757))
* **glasses:** add mock wearables dev mode setting for testing ([1744a8d](https://github.com/WiseLabCMU/wisescan-ios/commit/1744a8df993a8eabb6afab62f9e4c69ea0cb93e0))
* **glasses:** add PiP wearable stream on capture, mock wearables ([e055cdb](https://github.com/WiseLabCMU/wisescan-ios/commit/e055cdbdd27cf75c2e24ff301ecacf9e0329f3cd))
* **glasses:** add scaffolding to manage meta ray ban connect ([4b66558](https://github.com/WiseLabCMU/wisescan-ios/commit/4b66558632da22153e00cca5bbca0db7f0e1338a))
* **glasses:** added full meta rayban streaming glasses lifecycle ([90e9fc3](https://github.com/WiseLabCMU/wisescan-ios/commit/90e9fc303a662fa45c8a0ae2205f63feec981ee4))
* **glasses:** apply 7 fps privacy filter to wearable frames ([50bfdec](https://github.com/WiseLabCMU/wisescan-ios/commit/50bfdecf93ed5ec21cb8a5e08eb8a10f0d3b2471))
* **glasses:** integrated meta ray ban wearables ([31da78e](https://github.com/WiseLabCMU/wisescan-ios/commit/31da78e39d72cd4d02d41c9853d3e5dd68db7453))
* project test with automated screenshots ([1969966](https://github.com/WiseLabCMU/wisescan-ios/commit/1969966f1cc302e4b6fda0da184249194a14f034))
* setup scan cases (rescan/extend) user choice ([dda2238](https://github.com/WiseLabCMU/wisescan-ios/commit/dda22389a5283a8a015921213a3ddd66d9c69144))


### Bug Fixes

* add ghost mesh wireframe, color user customizable ([251656d](https://github.com/WiseLabCMU/wisescan-ios/commit/251656d1ba2c93b554530f4705b70f25b8ee399e))
* add init progress when starting ar session on capture view ([dd500d3](https://github.com/WiseLabCMU/wisescan-ios/commit/dd500d38c34f82e2eca13ecf7fb750e5dd5fe170))
* correct issue that forces a new space after 2 scans ([719c0f4](https://github.com/WiseLabCMU/wisescan-ios/commit/719c0f48137988bae1032ef77649937f6a005bbf))
* ensure ar overlay renders end at stop recording ([99ac528](https://github.com/WiseLabCMU/wisescan-ios/commit/99ac52881c44406cac8c5e28457541ce0614748f))
* fixed inability to delete new space ([0041ff3](https://github.com/WiseLabCMU/wisescan-ios/commit/0041ff33d5f6d31eeb4ef7cdecd82246f3867e9a))
* fixed store migration to hardwareDeviceModel ([340e24c](https://github.com/WiseLabCMU/wisescan-ios/commit/340e24c6ce28f96d8aead2c59b6f6eb672ce6a3d))
* **glasses:** add wearables models supported in user guide ([a82ea4a](https://github.com/WiseLabCMU/wisescan-ios/commit/a82ea4acfe509e464e19c964edee6a01d78a694d))
* **glasses:** handle meta pause, stop, reactive state ([75f3944](https://github.com/WiseLabCMU/wisescan-ios/commit/75f39442fc32ea7b61b8b7af21c0e9d41d28f3db))
* **glasses:** trigger deep link glasses registration ([fb6e211](https://github.com/WiseLabCMU/wisescan-ios/commit/fb6e21130113f82aeafc3191d274cdfa8db841b8))
* hardcode version 0.2.1 for off-tag release ([0b4ad97](https://github.com/WiseLabCMU/wisescan-ios/commit/0b4ad9745428ab13d06ec74a6e127be8f03ca07b))
* include proper export and bluetooth plist keys ([92d99b2](https://github.com/WiseLabCMU/wisescan-ios/commit/92d99b2ae3b948d04b41009b891f1b9c37e89e75))
* prevent glasses streaming when not on capture tab ([d4cc6f2](https://github.com/WiseLabCMU/wisescan-ios/commit/d4cc6f225380c9f5526f4dadd525ba4c6038aa90))
* privacy overlay modified to use full body ([30c7204](https://github.com/WiseLabCMU/wisescan-ios/commit/30c72045c0d4929a6fee198a18c65d7a41cd8abe))
* reduce wearables status logging ([39ac01b](https://github.com/WiseLabCMU/wisescan-ios/commit/39ac01bfb537981ad1753e0f3c281e4d5730d8e4))
* refactor location detail list for perf., bulk operations ([1eae8b8](https://github.com/WiseLabCMU/wisescan-ios/commit/1eae8b870a9d3f72d9523b619fed888f412d632b))
* **release:** configure release-please via config file instead of ios type ([2e6a9a8](https://github.com/WiseLabCMU/wisescan-ios/commit/2e6a9a81f3871b773b179e6b858ee6ea06f2f33b))
* relocalization reworked, warn user when saving low featrure points ([24f951a](https://github.com/WiseLabCMU/wisescan-ios/commit/24f951a5ad140f06f046e6d7934dc3ffcf693b5d))
* remove default upload url ([718cff9](https://github.com/WiseLabCMU/wisescan-ios/commit/718cff954fb36708e77f7b0611eff04feda3fcc5))
* support wearables v0.6.0 ([717f29d](https://github.com/WiseLabCMU/wisescan-ios/commit/717f29d8237e788b93ab2e03237ee7a44a0a0638))

## [0.2.1](https://github.com/WiseLabCMU/wisescan-ios/compare/v0.2.0...v0.2.1) (2026-03-20)


### Bug Fixes

* **build:** resolve appstore conflicts ([34c2853](https://github.com/WiseLabCMU/wisescan-ios/commit/34c2853cfb24e151fe46ef14c6e54379021e404d))

## [0.2.0](https://github.com/WiseLabCMU/wisescan-ios/compare/v0.1.0...v0.2.0) (2026-03-20)


### Features

* **capture:** add warning when blurry frames are created ([91577ab](https://github.com/WiseLabCMU/wisescan-ios/commit/91577abc28d0af87a5c3ecfded067e4bee549f27))
* **capture:** allow multiple extended scans group together ([77ea2b2](https://github.com/WiseLabCMU/wisescan-ios/commit/77ea2b2d4836dd59c2f799c1153967cea6b75e17))
* **capture:** implement nominal/recording states, remove Stream mode, improve memory ([d7c2595](https://github.com/WiseLabCMU/wisescan-ios/commit/d7c259510be825f151426fd44185b514eaa5a25f))
* **dev:** add developer mode, with camera flip for testing ([8610d21](https://github.com/WiseLabCMU/wisescan-ios/commit/8610d21e3867bb9a5263eea1d9aa03ecf0997988))
* **lite:** allow lite mode - no lidar support ([74b8c1c](https://github.com/WiseLabCMU/wisescan-ios/commit/74b8c1c679f219464db7ea480df2fe7f8fc0fffe))
* **privacy:** add detected human markers to mesh preview ([39bcfea](https://github.com/WiseLabCMU/wisescan-ios/commit/39bcfea10c830230c7341be8303a1d5cfe72ee6d))
* **privacy:** render 2d icon over privacy in mesh preview ([fd97ca0](https://github.com/WiseLabCMU/wisescan-ios/commit/fd97ca07f63681f1244dac5cdb30676d919efe04))
* **scan:** add scan capacity metrics, add dev mode ([633a857](https://github.com/WiseLabCMU/wisescan-ios/commit/633a8571d47a3bc6a235f3db6fd11c56e4c9aa94))
* **test:** support mock sensor data in simulation ([#4](https://github.com/WiseLabCMU/wisescan-ios/issues/4)) ([f406b2c](https://github.com/WiseLabCMU/wisescan-ios/commit/f406b2cdf39e56ff3d7d9d785b9121004a9da53f))
* **ui:** reorg scans into grid list view with details ([63925c7](https://github.com/WiseLabCMU/wisescan-ios/commit/63925c77cb0a6dee1b51d24eb77c83212ed90436))


### Bug Fixes

* **arkit:** Coordinator now tracks lastGhostMeshDataCount to detect these changes ([6ebbcb3](https://github.com/WiseLabCMU/wisescan-ios/commit/6ebbcb3f37b18af781e5afb3398352ff8fcc5971))
* **capture:** enable sceneDepth frame semantics for LiDAR depth capture ([6f9d7a2](https://github.com/WiseLabCMU/wisescan-ios/commit/6f9d7a244cb2837d73fac1e674867d098153a7a5))
* consolidate app defaults, add edit mode scan detail ([2ad827e](https://github.com/WiseLabCMU/wisescan-ios/commit/2ad827ee6df4c64da5cbe8f43e8353bb1c51ae83))
* correct ghost overlay snap during extend scan ([2ed6354](https://github.com/WiseLabCMU/wisescan-ios/commit/2ed6354be5da45754426a2418907ea23c2ccc019))
* correct privacu filter and remove 2d overlay ([699ba3f](https://github.com/WiseLabCMU/wisescan-ios/commit/699ba3f1b25ce68d23066ea4c433151e304b9836))
* correct privacy marker y-inversion from arkit ([fadb29d](https://github.com/WiseLabCMU/wisescan-ios/commit/fadb29ddd2b011a072e6bd9c240ed7bdb1640942))
* **export:** add SceneKit fallback for USDZ export, fix OBJ path validation ([9c4bcda](https://github.com/WiseLabCMU/wisescan-ios/commit/9c4bcdadeab3b05595c50e81a0824d1342150e7b))
* **export:** realign unique export types to native formats ([ead3017](https://github.com/WiseLabCMU/wisescan-ios/commit/ead3017b31a262a32c2bc90ccf11bf73f7037f5e))
* **export:** realign unique export types to native formats ([18dbc7e](https://github.com/WiseLabCMU/wisescan-ios/commit/18dbc7e1d2c3806de191748b0f281d8ca3717202))
* fix face anchors with 3×3 median depth kernel ([32804bb](https://github.com/WiseLabCMU/wisescan-ios/commit/32804bbaf2e10021599493e41bfbfc2a790585c2))
* improve 1st location label entry, decouple from post processing ([076bb68](https://github.com/WiseLabCMU/wisescan-ios/commit/076bb68834f985ed23258637974382d148cfe2a5))
* improve vertex coloring estimate ([bc23267](https://github.com/WiseLabCMU/wisescan-ios/commit/bc23267585a5f02652dccd06a5542712182ab328))
* increase dynamic coloring, add  Depth Occlusion Filter ([26d0e4b](https://github.com/WiseLabCMU/wisescan-ios/commit/26d0e4ba3347d3fa0d3595a34715a08c956f857b))
* ipad scan orientation lock ([2b4347c](https://github.com/WiseLabCMU/wisescan-ios/commit/2b4347c11d2544479ea2455d7bd269cfee4b1b3e))
* keep location naming responsive during post process ([808c0f7](https://github.com/WiseLabCMU/wisescan-ios/commit/808c0f7b085b23b305e14847e5c10df9091f6ba5))
* load scan list lazily to save processing in long lists ([bb4f9fa](https://github.com/WiseLabCMU/wisescan-ios/commit/bb4f9faf115e10855e570c5bbf78a4bf05377b07))
* portrait locked during capture to guarantee intrinsics ([1245b26](https://github.com/WiseLabCMU/wisescan-ios/commit/1245b26b3b1605e45d7755853a9e70050ad3a649))
* pre-release code review fixes ([ff1dee6](https://github.com/WiseLabCMU/wisescan-ios/commit/ff1dee6729bc4455158d1b2892555a76f763d5be))
* require both arkit + lidar capabilities ([3f427ff](https://github.com/WiseLabCMU/wisescan-ios/commit/3f427fffdf1c1b7f919efd6b045b5cf6f3d3df56))
* retrofit all defauly scan exports to scan4d type ([717e06a](https://github.com/WiseLabCMU/wisescan-ios/commit/717e06a75d63bd0645269c2ba474dbe27cdef8a9))
* rework scan location and delete scans flows ([89dfdba](https://github.com/WiseLabCMU/wisescan-ios/commit/89dfdba0222ec6ec960462d1d1a685440f908cfa))
* rework vertex colroing to post process ([4075258](https://github.com/WiseLabCMU/wisescan-ios/commit/407525855b50fc3e36483ee496e00ca26602d3c5))
* stabilzing write data for export ([c8e7125](https://github.com/WiseLabCMU/wisescan-ios/commit/c8e712513a069f45befc0a999402fb05813c2b71))
* update release please to latest ([0ef3d11](https://github.com/WiseLabCMU/wisescan-ios/commit/0ef3d11f27f43b2d2968cfe473342ca8ac74979c))
* **userguide:** split user guide into separate view to unclutter settings ([3bf8c03](https://github.com/WiseLabCMU/wisescan-ios/commit/3bf8c03431a4abfebaa1fff13085272bf1a7377e))
* vertex mapping Y inversion, add dev mode vertex tests ([56c9bb5](https://github.com/WiseLabCMU/wisescan-ios/commit/56c9bb5955ff0469d6209f24f65fe82dee929620))
* **zip:** flatten .zip structure raw data ([47c06ee](https://github.com/WiseLabCMU/wisescan-ios/commit/47c06ee85221ec40def091f3d04d93c89dc9f911))
* **zip:** rework consistant .zip save/upload feedback/errors ([5608b4e](https://github.com/WiseLabCMU/wisescan-ios/commit/5608b4e9e762a5862b0d41f2e20495630cfca432))

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
