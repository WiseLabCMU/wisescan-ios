# Voxel-Based Accumulated Point Cloud Preview

Build a sparse voxel hash map that accumulates high-confidence LiDAR depth + camera color across frames, producing a persistent, accurate 3D point cloud in the VR preview mode.

## Design Decisions (from interview)

| Parameter | Decision |
|---|---|
| Spatial extent | 8m cube |
| Voxel resolution | 2cm |
| Memory strategy | Sparse hash map (surfaces only, ~1-5% of volume) |
| Per-voxel data | RGBA (4 bytes) — running average color + observation count |
| Compute split | GPU integration + CPU mesh extraction |
| Integration trigger | Movement-based keyframing (5cm translation / 3° rotation) |
| Extraction rate | 2Hz max (every 500ms) |
| Scene graph | Single LowLevelMesh at world origin |
| Max rendered voxels | 500K (2M vertices, 3M indices) |
| Quality filter | Keep existing: high confidence + edge filter + 5m max + privacy |
| Live frame | Keep both: live single-frame + voxel accumulation layered together |
| Billboard size | 2.5cm (slight overlap for denser look, no visible gaps) |
| Voxel coloring | Texture atlas (avoids CustomMaterial SIGABRT risk) |

## Proposed Changes

### VoxelGrid Data Structure

#### [NEW] [VoxelGrid.swift](file:///Users/mwfarb/git/wisescan-ios/wisescan-ios/VoxelGrid.swift)

A Swift class managing the sparse voxel hash map on CPU, with a Metal buffer mirror for GPU integration.

- **Hash map**: `[VoxelKey: VoxelData]` where `VoxelKey` = packed `(x,y,z)` grid coordinates and `VoxelData` = `(r,g,b,count)` as 4 × `UInt8`
- **Grid params**: origin at `(-4, -4, -4)`, extent `8m`, cell size `0.02m` → 400³ possible coords
- **GPU buffer**: A flat `MTLBuffer` of `VoxelEntry` structs (key + RGBA) used as an append buffer by the integration kernel. After GPU integration, the CPU reads back new entries and merges them into the hash map.
- **Extraction method**: `extractMesh()` → scans all occupied voxels, writes billboard quad vertices (position + color) into a pre-allocated `MTLBuffer` for the LowLevelMesh. Capped at 500K voxels.
- **Memory estimate**: 500K voxels × (12 bytes key + 4 bytes RGBA) = ~8MB hash map + ~40MB vertex buffer = ~48MB total

---

### GPU Integration Kernel

#### [MODIFY] [PointCloud.metal](file:///Users/mwfarb/git/wisescan-ios/wisescan-ios/Shaders/PointCloud.metal)

Add a new `integrateVoxels` compute kernel:

- **Input**: depth texture, Y/CbCr camera textures, confidence texture, segmentation texture, camera transform, intrinsics
- **Per-thread** (one per depth pixel):
  1. Apply existing filters (NaN, range, confidence==2, edge, segmentation)
  2. Unproject depth pixel to 3D camera-local position using intrinsics
  3. Transform to world space using `cameraTransform`
  4. Quantize to voxel grid coords: `gridX = floor((worldX - originX) / cellSize)`
  5. Compute RGB from YCbCr camera sample
  6. Atomically append `(gridX, gridY, gridZ, R, G, B)` to the GPU append buffer
- **Append buffer**: A `device` buffer with an atomic counter. Each thread increments the counter and writes its entry. CPU reads back after completion.

> [!NOTE]
> We use an append buffer rather than direct hash map writes because GPU hash maps with atomic operations are complex and error-prone. The CPU merge step is fast (~1ms for 49K entries) and gives us a clean single-writer model.

---

### PointCloudManager Changes

#### [MODIFY] [PointCloudManager.swift](file:///Users/mwfarb/git/wisescan-ios/wisescan-ios/PointCloudManager.swift)

Major additions:

1. **VoxelGrid instance**: Create and own a `VoxelGrid` alongside the existing live point cloud
2. **Second LowLevelMesh**: A separate `ModelEntity` for the accumulated voxel mesh, placed at the world origin (not attached to any anchor)
3. **Integration dispatch**: On each keyframe, after the live point cloud dispatch, also dispatch the `integrateVoxels` kernel to populate the append buffer
4. **Extraction timer**: A `lastExtractionTime` timestamp. If >500ms since last extraction AND integration has completed, call `voxelGrid.extractMesh()` and update the voxel LowLevelMesh
5. **GPU completion handler**: In the command buffer completion handler, trigger the CPU merge of the append buffer into the hash map, then check if extraction is due

**Rendering pipeline per frame:**
```
Frame arrives (with movement > 5cm/3°)
  ├─ GPU: projectPointCloud (existing live mesh — instant feedback)
  ├─ GPU: integrateVoxels (write to append buffer)
  ├─ GPU completion callback:
  │   ├─ CPU: merge append buffer → hash map (~1ms)
  │   └─ if >500ms since last extraction:
  │       ├─ CPU: extractMesh → write voxel LowLevelMesh vertices
  │       └─ Update voxel ModelEntity
  └─ RealityKit renders both meshes simultaneously
```

---

### ARCoverageView Changes

#### [MODIFY] [ARCoverageView.swift](file:///Users/mwfarb/git/wisescan-ios/wisescan-ios/ARCoverageView.swift)

- Pass `session` to `PointCloudManager.update()` (needed for the voxel grid's world-space transform)
- No other changes needed — the voxel mesh is just another `ModelEntity` in the scene

## Resolved Questions

- **Billboard size**: Use **2.5cm quads** (slight overlap over the 2cm cell size) for a denser visual with no visible gaps between voxels.
- **Vertex coloring**: Use a **texture atlas** approach (pack voxel colors into a LowLevelTexture, map each quad via UV). This avoids `CustomMaterial` which caused SIGABRT crashes with RealityKit's AR video compositing pipeline. Same pattern as the existing live point cloud.

## Verification Plan

### Build Verification
- `xcodebuild` clean build with no errors

### Device Testing
1. Launch VR mode, verify live point cloud still works immediately
2. Walk slowly around a room — voxel mesh should progressively fill in behind the live frame
3. Return to a previously scanned area — existing voxels should be stable (no duplicates, no drift)
4. Check memory usage stays under ~100MB for a small office scan
5. Verify no "retaining ARFrames" warnings in console
6. Verify ARKit SLAM tracking remains stable (no "resource constraints" warnings)
