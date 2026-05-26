# Build & Lint

## Prerequisites
- Xcode must be the active developer toolchain (not just CLI tools):
  ```
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  ```
- SwiftLint installed via Homebrew: `brew install swiftlint`

## Build (CLI)
```bash
# Device validation (CI / no signing)
xcodebuild -scheme wisescan-ios -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO

# Simulator (local iteration) — Xcode 26 iPad simulators
xcodebuild -scheme wisescan-ios -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build
```
- `generic/platform=iOS` compiles for arm64 — correct for M5 iPad Pro, no device-specific flag needed
- `CODE_SIGNING_ALLOWED=NO` skips provisioning profiles (CI/local validation only)
- For actual device deploy, use Xcode with automatic signing
- **Simulator names changed in Xcode 26**: iPad simulators are `iPad Pro 13-inch (M5)`, `iPad Pro 11-inch (M5)`, `iPad Air 13-inch (M4)`, etc. — run `xcodebuild -scheme wisescan-ios -destination 'bad-name' build` to see the full available list

## Lint
```bash
swiftlint lint --quiet wisescan-ios/
```
- SwiftLint requires SourceKit from the full Xcode SDK — will crash if xcode-select points to CommandLineTools
- Many pre-existing errors exist in `main` (short identifiers in math code, long functions in `FrameCaptureSession`, `MeshPreviewView`, etc.) — when reviewing a branch, diff errors against `main` baseline:
  ```bash
  # Get baseline
  git stash && swiftlint lint --quiet wisescan-ios/ 2>&1 | grep ": error:" | sort > /tmp/main_errors.txt && git stash pop
  # Get branch errors
  swiftlint lint --quiet wisescan-ios/ 2>&1 | grep ": error:" | sort > /tmp/branch_errors.txt
  # Show only new errors
  comm -23 /tmp/branch_errors.txt /tmp/main_errors.txt
  ```
- Files with pre-existing violations that are suppressed with file-level `// swiftlint:disable` comments: `FrameCaptureSession.swift`, `ARCoverageView.swift`, `CaptureView.swift`

## Conventions
- Commit messages: semantic format, 50-char subject (`feat:`, `fix:`, `refactor:`, etc.)
- SwiftData stored strings use raw values; enums use `@Transient` computed properties with legacy mapping in getters to avoid breaking existing databases
- `@Observable` macro expansions need explicit `import simd` if the class uses `simd_float4x4` or similar types — SwiftUI's implicit re-export isn't sufficient for the macro context

## Architecture: Stitching / Scan Linking

### `PendingStitchLink` — deferred write pattern
- Never write `stitching.json` until the **target scan ID is known** (i.e., after `ScanFileManager.saveScan()` returns)
- `PendingStitchLink` holds both source AND target anchor data; only `targetScanId` is missing until save
- `CaptureView.writeStitchingLinkIfPending(targetScanId:)` is the single write point — called from `savePendingScan()` and the extend-flow branch of `performStopRecording()`
- Do **not** build `PendingStitchLink` at UI button-tap time (anchor data is unavailable); build it after AR relocalization confirms the boundary anchor

### AR Configuration
- Use `ARCoverageView.makeFreshConfiguration()` whenever resetting to a clean session (both extend and alignment flows)
- `sceneReconstruction` is managed by `updateUIView` based on `isRecording` state — don't set it manually in other flows; just call `run()` with the fresh config and let `updateUIView` re-enable mesh capture when recording starts
- `ARSessionDelegate` callbacks run on ARKit's internal queue — always dispatch UI/state updates to `@MainActor` via `DispatchQueue.main.async`

### `TrackingStatus` enum
- Use `ScanStats.trackingStatus: TrackingStatus` (not string comparisons) for tracking state in views
- `trackingStatus.isNormal` is the canonical check for "session has full positional tracking"

### `StitchingMetadataManager` — async I/O
- `write()` and `addLink()` dispatch to a private serial `ioQueue` — do not block on their return value for correctness; use the optional `completion` handler if you need confirmation
- `read()` and `hasLinks()` remain synchronous (files are tiny JSON; called from SwiftUI view bodies)

### `LocationManager.bestHeading`
- Use `locationManager.bestHeading: Double?` everywhere instead of inline `trueHeading > 0 ? trueHeading : magneticHeading` — it encapsulates the true-north fallback
