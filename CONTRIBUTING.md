# Contributing to WiSEScan iOS (Scan4D)

This document covers **development rules and conventions** specific to `wisescan-ios`. These rules are mandatory for all contributors, including automated/agentic coding tools.

## Development Rules

### 1. AR Session Lifecycle — Keep It Warm

Use `@AppStorage` for persistent user preferences and UI toggles.

**Do NOT tear down or pause the `ARSession` just because the user navigated between tabs.** On a marginal (pre-A14) device a full camera + VIO cold start blocks the **main thread for ~13 s** — we tried teardown-for-battery and it was a hard regression (see the Performance section). Keep **one warm session** for the whole capture lifecycle.

- Battery is reclaimed by an **idle timer** (`AppConstants.arIdleTeardownSeconds`) that pauses the session **only after the user has left the capture tab and stayed away**; returning resumes in the nominal config with no main-thread stall. Rapid successive scans return before it fires and stay hot.
- Leaving the capture **tab** abandons an in-progress Extend (its ghost/world-map state is cleared in `CaptureView.onDisappear`); the user re-taps Extend to restore it. A modal sheet *over* the capture screen (e.g. Settings) does **not** leave the tab, so it stays hot — that's intentional (user may be flipping AR↔VR before recording).

### 2. Privacy Filtering Patterns

Privacy has two distinct paths — **do not conflate them**:

- **Live on-screen indicator:** a cheap **red-eye marker** per person, driven entirely by ARKit's already-computed `.personSegmentationWithDepth` stencil (`ARFrame.segmentationBuffer`) — **no per-frame Vision pass and no CoreImage render**. Running a per-frame `VNGeneratePersonSegmentationRequest` for a live overlay starves VIO (see Performance). The indicator uses a small retained confidence grid (`PrivacyEyeTracker`) so markers don't flicker.
- **Saved data (the actual privacy guarantee):** exported JPEGs pixelate person regions and depth maps zero them out. Blur from the ARKit stencil when present, but **always keep a Vision fallback** (`pixelatePersonsAndGetFaceCenters`) for frames where the stencil is missing (unsupported device or a momentary gap right after the session starts). **A missing stencil must never silently write an unblurred frame** — fall back, or drop the frame; never leak a face.
- **Mesh exports:** person geometry is excluded from the exported mesh/point cloud.
- **3D anchors:** re-source `face_anchors` from the **stencil**, not a second Vision pass — one confidence-weighted, observation-gated body-center centroid **per person** (not per grid cell, or they fragment across the body).

### 3. Code Style & Architecture

- **SwiftUI First:** All new views should be written using SwiftUI rather than storyboards.
- **Data Model:** Follow the hierarchical `Locations` -> `Scans` data model pattern.
- **SwiftData enums:** Stored strings use raw values; expose enums via `@Transient` computed properties with legacy mapping in the getters, so adding/renaming cases never breaks existing on-device databases.
- **`@Observable` + simd:** A class using `simd_float4x4` (or similar simd types) needs an explicit `import simd` — the `@Observable` macro expands in a context where SwiftUI's implicit re-export is not sufficient.

### 4. Dependencies — Pin All Versions

**All dependencies must use exact, pegged versions** (no `^`, `~`, or `*` ranges). This prevents version drift across environments and ensures reproducible builds for security.

### 5. Magic Numbers & Constants

**No magic numbers allowed inline.** Any numerical layout properties, structural modifiers (like opacities, heights, constraints), and complex configurations (duration bounds, bitrates) must be formally extracted and organized into the `AppConstants.swift` structure. This guarantees centralized governance of our UI aesthetics and networking policies.

### 6. Camera Coordinate Space & Orientations

To ensure exported data (images, depth maps, camera intrinsics, and Scan4D metadata) produces accurate results for server-side processing (e.g., COLMAP):
- ARKit and AVFoundation natively output raw buffers in **LandscapeRight**.
- **Data Export:** Exported JPEGs, PNG depth maps, and their corresponding intrinsics must remain in this native, unrotated LandscapeRight format. Do not pre-rotate images to match the UI, as this breaks the alignment between the image pixels and the intrinsic matrix parameters (`cx`, `cy`).
- **Current approach — portrait lock (REQ-026):** the capture view is **locked to portrait** (`AppDelegate.orientationLocked` + portrait-only `UISupportedInterfaceOrientations`). Because the sensor buffer is therefore always LandscapeRight, the live overlay uses a *fixed* sensor→portrait map (`(u,v) → (1-v, u)`, i.e. `UIImage(orientation: .right)`) rather than reading the live interface orientation. Three layers must agree on orientation (RealityKit scene, the SwiftUI privacy overlay, scene geometry) — the lock is what keeps them aligned. See the orientation architecture docs in `FaceBlurOverlay.swift`.
- **Future (do not do piecemeal):** when Apple forces all-orientation support on iPad (`UIRequiresFullScreen` deprecation), replace the lock with dynamic handling — read the interface orientation to compute `CGImagePropertyOrientation` for Vision and `UIImage.Orientation` for the overlay — across **all** layers and both capture modes at once. Don't hardcode a new fixed rotation to "fix" one layer; that just moves the misalignment.

## Performance & Reality-Capture Integrity (hard-won — do not regress)

These rules come directly from the `perf/vio-starvation-diagnostics` investigation. The failure mode they prevent is **ARKit VIO starvation**: when the main thread (or the camera frame pool) is blocked, ARKit stops delivering frames, dead-reckons on the IMU, and tracking diverges — visible as a 1–13 s freeze plus drifted geometry, and in the log as `ARSession ... is retaining N ARFrames`.

### Never block the main thread during capture or stop
The single root cause behind every freeze we chased. Keep heavy work off main:
- File I/O (per-frame JSON, mesh/world-map writes), JPEG/PNG encodes, and mesh export run on background queues. At stop, `pauseCapture()` (cheap, main) then flush on a utility queue.
- RealityKit/SceneKit and SwiftUI bindings **must** be touched on main — dispatch those *to* main from background work; don't move them off.
- Don't present a keyboard/alert over a still-rendering live `ARView`. We leave the capture screen first (switch to the Scans tab) so the name prompt is instant.

### The ARSession delegate must run off the main thread
Set `session.delegateQueue` to a **serial background queue** (see `Coordinator.sessionDelegateQueue`). If the delegate runs on main (the default when unset), a busy main thread stalls the frame pool. Invariants once it's off-main:
- Every RealityKit/entity/binding mutation is dispatched **to main**.
- Delegate-owned dictionaries/counters are touched **only on the delegate queue** (concurrent mutation from main crashes).

### Reuse ARKit's segmentation stencil — don't add Vision passes to hot paths
A per-frame `.accurate VNGeneratePersonSegmentationRequest` cost **180–360 ms/frame** and was the dominant capture-side starvation source. ARKit already produces `.personSegmentationWithDepth` for the depth cutout and point-cloud holes — reuse `ARFrame.segmentationBuffer` for blur, anchors, and the live indicator. Vision is a **fallback only** (see Privacy).

### Bound the capture I/O backlog
Capture coalesces: it won't enqueue a new save while a prior encode is in flight (`AppConstants.maxFramesInFlight`). Unbounded encodes pile up retained `CVPixelBuffer`s and starve the frame pool. Capture is movement-gated, so dropping a frame under load is fine — the next motion re-triggers.

### Mesh/anchor hygiene across scans
The session stays warm, so it **retains `ARMeshAnchor`s between scans**. A **new** scan's record-start must run with `.removeExistingAnchors`, or a previous scan's geometry bleeds into this scan's export (`exportMeshOBJ` enumerates the live `currentFrame.anchors`). An **extend** deliberately preserves anchors (it's re-meshing the relocalized frame).

### Never silently save a non-relocalizable scan
If `getCurrentWorldMap` fails (insufficient features / serialize error / timeout), **surface it** — prompt Try Again / Save Without Map — instead of saving with `worldMapURL == nil` and only a card badge. The pre-save `mappingStatus` gate is throttled and can disagree with the real export, so don't rely on it alone.

### Debugging with PerfDiag
`PerfDiag` (in `PerfDiag.swift`) is the instrumentation for all of the above. It is a **no-op unless** Developer Mode → **Perf Diagnostics** is on, so its calls are safe to leave in hot paths. Output goes to `OSLog` (subsystem `org.arenaxr.scan4d`, category `perf`) — watch it live in Console.app/Xcode — and to `os_signpost` intervals for the Instruments timeline.
- **`MainThreadWatchdog`** logs `main-thread stall BEGIN/END (max no-frame gap Nms)` — the visible freeze.
- The **frame-gap logger** logs `ARKit frame gap Nms` and every tracking-state transition — the VIO-starvation smoking gun.
- The **I/O backlog counter** logs when in-flight encodes exceed the cap; GPU/voxel passes log over-budget durations (`voxel_merge`, `voxel_decay`, `privacy_blur_mask`, etc.).
- Wrap new discrete hot operations in `PerfDiag.timed("label", warnOverMs:)` rather than guessing — **measure before changing** (guessing here caused regressions).
- Add toggles to the Developer Mode section of `SettingsView` for any new isolation switch (mirror `pauseVRCompute`).

## Build & Test

To build the project locally, open `wisescan-ios.xcodeproj` with Xcode.

The `wisescan-ios` repository uses [Release Please](https://github.com/googleapis/release-please) to automate CHANGELOG generation and semantic versioning. Your PR titles *must* follow Conventional Commit standards (e.g., `feat:`, `fix:`, `chore:`). Keep commit subjects to ~50 chars. Fastlane is used to automate TestFlight deployments via `fastlane testflight`.

For CLI build and lint commands (CI / no-signing validation, SwiftLint baseline diffing), see [docs/BUILDING.md](docs/BUILDING.md). For the full release process, see [docs/RELEASE.md](docs/RELEASE.md).

## Stitching / Scan Linking — Implementation Contract

Hard-won invariants for the Extend Scan / map-stitching flow (REQ-003, REQ-012). Design rationale lives in [docs/design/Scan4D_Architecture.md](docs/design/Scan4D_Architecture.md).

### `PendingStitchLink` — deferred write pattern
- Never write `stitching.json` until the **target scan ID is known** (i.e., after `ScanFileManager.saveScan()` returns).
- `PendingStitchLink` holds both source AND target anchor data; only `targetScanId` is missing until save.
- `CaptureView.writeStitchingLinkIfPending(targetScanId:)` is the single write point — called from `savePendingScan()` and the extend-flow branch of `performStopRecording()`.
- Do **not** build `PendingStitchLink` at UI button-tap time (anchor data is unavailable); build it after AR relocalization confirms the boundary anchor.

### AR configuration
- Use `ARCoverageView.makeFreshConfiguration()` whenever resetting to a clean session (both extend and alignment flows).
- `sceneReconstruction` is managed by `updateUIView` based on `isRecording` state — don't set it manually in other flows; just call `run()` with the fresh config and let `updateUIView` re-enable mesh capture when recording starts.
- `ARSessionDelegate` callbacks run on ARKit's internal queue — always dispatch UI/state updates to `@MainActor` via `DispatchQueue.main.async`. (See also the off-main delegate-queue rules in the Performance section above.)

### `TrackingStatus` enum
- Use `ScanStats.trackingStatus: TrackingStatus` (not string comparisons) for tracking state in views.
- `trackingStatus.isNormal` is the canonical check for "session has full positional tracking".

### `StitchingMetadataManager` — async I/O
- `write()` and `addLink()` dispatch to a private serial `ioQueue` — do not block on their return value for correctness; use the optional `completion` handler if you need confirmation.
- `read()` and `hasLinks()` remain synchronous (files are tiny JSON) but should be loaded via `.task` into `@State` rather than called directly in a SwiftUI `body`, to avoid repeated I/O on every re-render.

### `LocationManager.bestHeading`
- Use `locationManager.bestHeading: Double?` everywhere instead of inline `trueHeading > 0 ? trueHeading : magneticHeading` — it encapsulates the true-north fallback.
