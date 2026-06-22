# Building & Linting

CLI build, lint, and CI-validation workflows for Scan4D (wisescan-ios). For local development you can also just open `wisescan-ios.xcodeproj` in Xcode.

## Prerequisites
- Xcode must be the active developer toolchain (not just CLI tools):
  ```bash
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  ```
- SwiftLint installed via Homebrew: `brew install swiftlint`
- Git hooks (one-time, after cloning) — install the pre-commit hook:
  ```bash
  ./scripts/install-hooks.sh
  ```
  It blocks a commit if Xcode's project serializer has silently stripped the `x-release-please-version` markers from `project.pbxproj`. Xcode rewrites that file whenever you open the project or change a build setting, so it's easy to stage a reserialized version with the markers gone — the hook catches it before it lands. See [CONTRIBUTING.md](../CONTRIBUTING.md) for why the markers matter.

## Build (CLI)
```bash
# Device validation (CI / no signing)
xcodebuild -scheme wisescan-ios -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO

# Simulator (local iteration) — list available destinations first
xcodebuild -scheme wisescan-ios -showdestinations | grep 'platform:iOS Simulator'
# Then use a destination from the list, e.g.:
xcodebuild -scheme wisescan-ios -destination 'platform=iOS Simulator,name=iPad Air 13-inch (M4)' build
```
- `generic/platform=iOS` compiles for arm64 — correct for iPad Pro, no device-specific flag needed
- `CODE_SIGNING_ALLOWED=NO` skips provisioning profiles (CI/local validation only)
- For actual device deploy, use Xcode with automatic signing
- Simulator names change across Xcode versions — always verify with `-showdestinations` before scripting builds

## Lint
```bash
swiftlint lint --quiet wisescan-ios/
```
- SwiftLint requires SourceKit from the full Xcode SDK — will crash if `xcode-select` points to CommandLineTools
- Many pre-existing errors exist in `main` (short identifiers in math code, long functions in `FrameCaptureSession`, `MeshPreviewView`, etc.) — when reviewing a branch, diff errors against the `main` baseline:
  ```bash
  # Get baseline
  git stash && swiftlint lint --quiet wisescan-ios/ 2>&1 | grep ": error:" | sort > /tmp/main_errors.txt && git stash pop
  # Get branch errors
  swiftlint lint --quiet wisescan-ios/ 2>&1 | grep ": error:" | sort > /tmp/branch_errors.txt
  # Show only new errors
  comm -23 /tmp/branch_errors.txt /tmp/main_errors.txt
  ```
- Files with pre-existing violations suppressed via file-level `// swiftlint:disable` comments: `FrameCaptureSession.swift`, `ARCoverageView.swift`, `CaptureView.swift`

## Release & TestFlight
See [RELEASE.md](RELEASE.md) — release-please versioning and Fastlane TestFlight distribution.
