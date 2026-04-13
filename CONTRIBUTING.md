# Contributing to WiSEScan iOS (Scan4D)

This document covers **development rules and conventions** specific to `wisescan-ios`. These rules are mandatory for all contributors, including automated/agentic coding tools.

## Development Rules

### 1. View Lifecycle & Persistent Settings

Use `@AppStorage` for managing persistent user preferences and UI toggles.

**Critical:** You must ensure the `ARSession` is paused/terminated correctly when navigating away from the reality capture views. Failing to do so can result in orphaned recordings, battery drain, and memory leaks.

### 2. Privacy Filtering Patterns

Any new computer vision exports or data pipelines must respect user privacy. We utilize person segmentation via Vision/CoreImage to automatically identify humans in the frame.
- **Mesh Exports:** Vertex filtering should be applied to remove humans from exported geometry.
- **Camera Frames:** Real-time facial blurring must be applied to video/image captures.

### 3. Code Style & Architecture

- **SwiftUI First:** All new views should be written using SwiftUI rather than storyboards.
- **Data Model:** Follow the hierarchical `Locations` -> `Scans` data model pattern.

### 4. Dependencies — Pin All Versions

**All dependencies must use exact, pegged versions** (no `^`, `~`, or `*` ranges). This prevents version drift across environments and ensures reproducible builds for security.

## Build & Test

To build the project locally, open `wisescan-ios.xcodeproj` with Xcode.

The `wisescan-ios` repository uses [Release Please](https://github.com/googleapis/release-please) to automate CHANGELOG generation and semantic versioning. Your PR titles *must* follow Conventional Commit standards (e.g., `feat:`, `fix:`, `chore:`). Fastlane is used to automate TestFlight deployments via `fastlane testflight`.
