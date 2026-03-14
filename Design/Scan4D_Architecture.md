# Scan4D Architectural Design

## Overview
Scan4D allows users to perform time-series scanning of the same physical space to track changes over time. The system will guide users to re-scan previously mapped areas, rendering an overlay of prior scans to detect moved furniture or altered structures.

## Core Mechanisms: Spatial Anchoring & Relocalization

To perfectly overlay a past scan onto a current session and track changes over time, the system needs to align coordinate systems. Our architecture divides this responsibility between the **Edge Device (Live UI)** and the **Backend Server (Ultimate Truth)**.

### The Backend Pipeline (The Ultimate Source of Truth)
The hackable backend server is responsible for the definitive, high-fidelity alignment of time-series scans.
- **How it works:** Incoming scans provide a categorical **GPS / Anchor Tag ground truth offset**. The server then uses robust algorithms like **ICP (Iterative Closest Point)** or feature-matching via **OpenFLAME** to mathematically align the new mesh/splat to the historical baseline.
- **Why it's better:** It is ecosystem-agnostic, infinitely scalable in compute, and allows researchers to swap in novel localization algorithms without updating the iOS app.

### The Edge Device (Live Session Guidance)
If the backend does the real alignment, why do we need relocalization on the iOS device during capture? **To render the "ghost skeleton."**
Live relocalization is crucial to show the user what was previously scanned, guiding their coverage and highlighting real-time differences. We have several options for this live edge-anchoring:

#### 1. ARKit World Map (`ARWorldMap`) - *Current Default*
- **How it works:** We save the ARKit map of feature points and upload it alongside the mesh as a categorical asset. When "Scanning Again," the app downloads (or loads locally) this map to explicitly snap the current ARSession to the historical coordinates.
- **Pros:** Native to ARKit, powers the live ghost UI immediately.
- **Cons:** Very sensitive to lighting/structural changes; large file sizes.

#### 2. OpenFLAME Live Localization (Server-Assisted)
- **How it works:** The device streams lightweight visual features to the server. The server runs OpenFLAME localization against the historical index and streams back a coordinate correction transform to the device in real-time.
- **Pros:** Bypasses `ARWorldMap` fragility; centralizes the logic.
- **Cons:** Requires a robust, low-latency network connection to the backend during capture.

#### 3. Image Anchors / Visual Fiducials (AprilTags)
- **How it works:** Standardized markers in the environment provide an immediate, 100% reliable local coordinate snap.
- **Pros:** Perfect for controlled lab environments; incredibly robust over time.
- **Cons:** Requires physical infrastructure.

#### 4. Apple RoomPlan API (Deprioritized)
- **How it works:** AI bounding boxes for walls/furniture.
- **Verdict:** Deprioritized. It is heavily tied to the Apple ecosystem. Semantic understanding and structural extraction are tasks better suited for the hackable backend pipeline rather than the edge client.

### Recommendation: The GPS-Seeded Hybrid Approach
1. **Always capture rough Ground Truth:** Every scan must log GPS coordinates (and/or visible AprilTags) to give the server a starting offset.
2. **Package everything:** Upload the Mesh, RAW data, AND the `ARWorldMap` in the payload. The server has all the data it needs.
3. **Edge-driven UI:** Use `ARWorldMap` (or eventually live OpenFLAME queries) *strictly* to power the in-app ghost overlay and guide user coverage. Leave the final, perfect mesh alignment to the backend ICP pipeline.

## Data Model & Hierarchy

To support time-series data locally (and eventually via a backend), we need a structured data model.

```swift
struct LocationEntity {
    let id: UUID
    var name: String // e.g., "Conference Room A"
    var approximateLocation: CLLocation? // GPS for macro-filtering
    var scans: [ScanSnapshot]
}

struct ScanSnapshot {
    let id: UUID
    let date: Date
    let meshDataURL: URL // The .obj or binary mesh file
    let worldMapURL: URL? // The saved ARWorldMap for relocalization
    let thumbnailURL: URL?
    var notes: String?
}
```

**Storage Planning:**
- **Local:** Store meshes in the App's Document directory, categorized by `LocationEntity.id`. Use SQLite or SwiftData to manage the relational metadata.
- **Cloud (Future):** Meshes are large. Implement compression and chunking. A backend like AWS S3 for binary files and a relational DB for metadata.

## User Interface & Workflow

### 1. The "Locations" Tab (New)
Instead of just a flat list of scans, the app opens to a list of known "Locations".
- Users can create a new Location or select an existing one.

### 2. Location Detail View
- Shows a reverse-chronological list of `ScanSnapshot`s.
- "Scan This Location Again" button.

### 3. The Scan4D Capture Workflow
**Phase 1: Relocalization**
- User taps "Scan Again".
- Camera opens, prompting: "Look around to recognize the room." (ARKit is trying to load the last `ARWorldMap`).
- *UI:* A ghostly skeleton of the last scan is faintly visible, locked to the world coordinates once recognized.

**Phase 2: Differential Scanning**
- The user begins scanning.
- **Visual Feedback:**
    - The *old* scan is rendered in a faint, transparent red or gray.
    - The *new* coverage overlay (our striped pattern) fills in as they scan.
    - *Advanced:* If the new mesh geometry significantly differs from the old mesh geometry at the same coordinates, highlight the area in bright yellow to indicate a "Change Detected" (e.g., a moved chair).

## Multi-Device / Backend Sync Considerations (The Hard Part?)
- **Coordinate System Drift:** An `ARWorldMap` created on an iPhone 14 Pro might have slightly different scale/drift characteristics than one created on an iPad Pro weeks later.
- **File Sizes:** Downloading a 50MB `ARWorldMap` and a 100MB mesh over cellular before a scan can be frustrating. We need background syncing.
- **Privacy:** Sharing spatial maps of private areas requires robust access control.

## Large-Space Scanning & Map Stitching

### The Problem
Time-series relocalization (scanning the same place over time) is only one dimension of the relocalization challenge. The other is **spatial-extent relocalization** — scanning spaces too large to capture in a single session.

Real-world users (e.g., Sagar's workflow) currently scan large areas (e.g., an entire floor) as multiple smaller chunks in Polycam, then manually stitch them together in post-processing. This is partly because Polycam doesn't handle large areas well in a single shot, but the question is: **is this a fundamental ARKit limitation, or just a UX/app problem?**

### ARKit Scene Reconstruction Limits

There is **no explicit hard limit or warning** from ARKit when a scene gets too large. Instead, quality degrades gradually:

| Factor | Behavior |
|:---|:---|
| **Mesh segmentation** | ARKit generates meshes in ~1m × 1m segments that overlap to form a continuous surface. This is modular and technically unbounded. |
| **Dynamic tessellation** | RealityKit/ARKit dynamically reduces mesh quality (lower polygon density) in areas further from the camera to manage hardware resources. This means large scenes get progressively coarser in already-scanned regions. |
| **LiDAR range** | The sensor is effective up to ~5m, sometimes ~7m. Beyond that, geometry data becomes sparse and unreliable. |
| **SLAM drift** | ARKit's visual-inertial SLAM accumulates positional drift over time and distance. Featureless or repetitive environments (hallways, construction sites, malls) accelerate this. |
| **Memory pressure** | No documented ceiling, but ARKit tracks all mesh anchors in memory. A very large session (think: an entire mall floor) will consume significant RAM and eventually trigger iOS memory warnings. |
| **No explicit warning** | ARKit does **not** fire a delegate callback or notification when the scene is "too big." Old scanner apps (like the pre-LiDAR Structure Sensor apps) implemented their own polygon/vertex counters and warned manually. |

**Bottom line:** At some point, no single ARKit session will be big enough for truly large spaces (construction sites, malls, multi-floor buildings). The app should detect practical limits (via polygon count, drift metrics, or session duration) and **recommend the user stop and start a new session**, rather than waiting for a crash.

### Design Strategies

#### Strategy A: Single Large Session (Simplest, May Hit Ceiling)
Just let ARKit run continuously and hope the WorldMap holds up.

- **Pros:** No stitching needed; one coordinate space.
- **Cons:** Drift accumulation, potential memory pressure, quality degradation in large/repetitive spaces. Unknown hard ceiling on WorldMap size.
- **Verdict:** Worth testing empirically to find the breaking point before investing in stitching infrastructure.

#### Strategy B: Chunked Scans with Shared Coordinate Space
Scan in overlapping chunks. Each chunk shares a common coordinate frame by relocalizing against the *same* WorldMap saved from the first chunk's session.

- **How it works:**
  1. Scan chunk 1 → save WorldMap + mesh.
  2. Scan chunk 2 → load chunk 1's WorldMap to relocalize, then extend the session into new territory. Save the *extended* WorldMap.
  3. Repeat, always loading the latest cumulative WorldMap.
- **Pros:** All chunks share a coordinate system; stitching is implicit.
- **Cons:** The WorldMap grows with each chunk, eventually hitting the same ceiling. Relocalization may fail if you start chunk N far from chunk N-1's coverage.

#### Strategy C: Independent Chunks with Server-Side Stitching ⭐ Recommended for Large Spaces
Scan independently, let the backend align them. This is the most scalable approach.

- **How it works:** Each scan captures its own WorldMap + mesh + RAW images independently. The server uses photogrammetry to find shared features across overlapping regions and compute global alignment transforms.
- **Pros:** No ARKit limitations matter — crude LiDAR meshes are sufficient for coverage; real reconstruction happens server-side from RAW imagery. Scales to arbitrary space sizes.
- **Cons:** Requires overlapping coverage between chunks. No live cross-chunk ghost overlay on device (user won't see previous chunks during capture unless we solve the multi-map problem).

**COLMAP can do this.** Specifically:
- Feed images from all scan sessions into a shared COLMAP database (feature extraction + matching).
- If overlap is sufficient, COLMAP aligns everything into a single reconstruction automatically.
- If overlap is insufficient, COLMAP produces multiple "components" (disconnected models). These can be merged using:
  - `model_merger` — merges sub-models that share common registered images.
  - `hierarchical_mapper` — automatically clusters large scenes into overlapping sub-models, reconstructs in parallel, then merges.
  - `model_aligner` — geo-registers models using known camera positions (e.g., GPS from the phone).
- COLMAP also supports `model_orientation_aligner` for Manhattan-world alignment (gravity axis + major axes from vanishing points), useful for architectural/indoor scenes.

**RealityCapture can also do this** (and is simpler for users):
- Import all images from all sessions → click "Align Images" → if sufficient overlap exists, everything auto-aligns into one component.
- If multiple components result, merge them via: re-running alignment with bridging images, manual control points on shared features, or GPS-based georeferenced merging.
- RealityCapture is commercial but very fast and handles massive datasets well.
- **Recommended overlap: >60%** between neighboring images for reliable alignment.

**Key question answered:** Yes, both COLMAP and RealityCapture can take all images from multiple smaller scans and automatically align them into a unified coordinate system if there's decent overlap between sessions. The ARKit per-session camera poses (from `transforms.json`) also give each tool strong initialization hints.

#### Strategy D: Out-of-Band Localization (SuperGlue / hloc / OpenFLAME)
Replace WorldMap relocalization entirely with our own feature-based localization.

- **How it works:** Extract visual features (SuperPoint/SuperGlue) from each scan's images. At scan-again time, run live feature matching on-device or via server to compute the 6-DOF pose relative to the historical feature database. This gives us the transform to render the ghost mesh without needing an ARWorldMap at all.
- **Pros:** Decouples from ARKit's single-WorldMap limitation entirely. Can handle multi-floor, multi-building scenarios. The same infrastructure works for both time-series and spatial stitching.
- **Cons:** Requires significant engineering investment. On-device SuperGlue may be too slow for real-time; server-assisted adds latency dependency. Need low-level access to camera intrinsics and feature extraction.
- **Note:** This is the path that enables Quest-like "recognize any known space" behavior.

### Practical UX Recommendation: Stop-and-Resume

For the near term, the simplest path for large spaces:
1. **On-device:** Let the user scan in natural chunks. When they feel they've covered enough of an area (or if we detect quality degradation), prompt them to stop and start a new session. Ensure the user overlaps coverage at boundaries.
2. **Bundle all chunks under one Location**, tagged as belonging to the same spatial scan group.
3. **Server-side:** Feed all RAW bundles from the group into COLMAP/RealityCapture for automatic coordinate alignment and unified reconstruction.
4. **The device never needs to stitch** — it only captures and annotates. The intelligence lives on the server.

### Key Insight: Crude Mesh is Enough

We don't need ARKit to produce a final mesh. **ARKit's LiDAR mesh is a crude spatial scaffold — the real reconstruction happens server-side from RAW images** using photogrammetry pipelines (COLMAP → NeRF/3DGS). This means:
- The on-device mesh only needs to be good enough to guide coverage and render a ghost overlay.
- Even if ARKit's mesh quality degrades in large sessions, the RAW capture data remains valid for server reconstruction.
- This decouples scan *quality* from scan *extent*.

### Recommended Investigation Path
1. **Empirical testing:** Determine the practical ceiling of a single ARKit session — scan a full floor and measure drift, WorldMap size, memory pressure, and mesh quality vs. area covered.
2. **Strategy B prototype:** Test the "cumulative WorldMap" approach with 2–3 overlapping chunks to see if relocalization holds across boundaries.
3. **RAW-first pipeline:** Since we already capture RAW bundles (images + poses + depth), validate that server-side photogrammetry (COLMAP or RealityCapture) can stitch independent chunks from overlapping imagery alone, without needing WorldMap alignment.
4. **Evaluate SuperGlue feasibility:** If Strategies A/B hit hard ceilings, prototype on-device or server-assisted feature matching as a WorldMap replacement.

## Next Steps for Prototyping
If we want to prototype Scan4D, I recommend starting purely locally:
1. Update `ScanStore` to support the `Location` -> `Scans` hierarchy.
2. Implement saving and loading of `ARWorldMap` alongside the mesh data.
3. Build a prototype Capture view that loads the latest `ARWorldMap` for a selected location and overlays the old mesh as a static, semi-transparent RealityKit entity.
