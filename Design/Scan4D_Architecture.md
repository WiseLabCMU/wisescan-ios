# Scan4D Architectural Design

## Overview
Scan4D allows users to perform time-series scanning of the same physical space to track changes over time. The system will guide users to re-scan previously mapped areas, rendering an overlay of prior scans to detect moved furniture or altered structures.

## Core Mechanisms: Spatial Anchoring

To perfectly overlay a past scan onto a current AR session, the system must recognize the physical space and align coordinate systems. We have several options:

### 1. ARKit World Map (`ARWorldMap`)
- **How it works:** ARKit continuously builds a map of the space (feature points, plane anchors). We can save this map and reload it in a subsequent session.
- **Pros:** Native to ARKit, highly accurate relocalization (often sub-centimeter).
- **Cons:** Extremely sensitive to lighting changes and major physical shifts. If the room looks significantly different, relocalization will fail. File sizes can be large.
- **Best Use:** Same-day or very short-term rescans.

### 2. Apple RoomPlan API (iOS 16+)
- **How it works:** Uses machine learning to detect room layout (walls, windows, doors, furniture bounding boxes).
- **Pros:** Very robust against minor moved objects (chairs, tables). The core room structure serves as the anchor.
- **Cons:** Less granular than raw mesh reconstruction.
- **Best Use:** Structural alignment and semantic understanding.

### 3. Image Anchors / Visual Fiducials (`ARImageAnchor` / AprilTags)
- **How it works:** Place a known physical marker (QR code, printed AprilTag, or a distinctive poster) in the room. The system aligns the coordinate system to this marker.
- **Pros:** 100% reliable relocalization as long as the marker hasn't moved. Incredibly robust across time, lighting, and device changes.
- **Cons:** Requires physical markers in the environment.
- **Best Use:** Industrial, lab, or controlled environments.

### 4. Custom Point Cloud / Mesh Alignment (ICP - Iterative Closest Point)
- **How it works:** Load the previous 3D mesh and align the new incoming LiDAR mesh to it mathematically in real-time.
- **Pros:** Can handle moderate changes, doesn't rely on Apple's transient feature points.
- **Cons:** Computationally heavy, complex to implement efficiently on mobile.

### Recommendation: Hybrid Approach
For Scan4D, a hybrid approach is standard in the industry:
1. **Primary:** `ARWorldMap` (try native relocalization first).
2. **Fallback/Assisted:** Image Anchors. We can prompt the user to scan a specific known object/poster in the room to "snap" the coordinate systems together if automatic world map relocalization fails.
3. **Optional:** Location-based grouping (GPS + Wi-Fi fingerprinting) to suggest which scan the user is currently near.

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
