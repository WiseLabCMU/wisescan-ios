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

## Next Steps for Prototyping
If we want to prototype Scan4D, I recommend starting purely locally:
1. Update `ScanStore` to support the `Location` -> `Scans` hierarchy.
2. Implement saving and loading of `ARWorldMap` alongside the mesh data.
3. Build a prototype Capture view that loads the latest `ARWorldMap` for a selected location and overlays the old mesh as a static, semi-transparent RealityKit entity.
