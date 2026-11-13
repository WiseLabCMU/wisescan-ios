# Building & Linting

CLI build, lint, and CI-validation workflows for Scan4D (scan4d-ios). For local development you can also just open `scan4d-ios.xcodeproj` in Xcode.

## Prerequisites
- Xcode 26.6 or later (the project's last upgrade check is 26.6, the deployment target is iOS 18.0, CI compiles on 26.6, and Xcode 27 is in use on lab Macs).
- Xcode must be the active developer toolchain (not just CLI tools):
  ```bash
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  ```
- SwiftLint installed via Homebrew: `brew install swiftlint`
- Git hooks (one-time, after cloning) — install the pre-commit hook (release-please marker check + privacy guard) and the pre-push backstop:
  ```bash
  ./scripts/install-hooks.sh
  ```
  It blocks a commit if Xcode's project serializer has silently stripped the `x-release-please-version` markers from `project.pbxproj`. Xcode rewrites that file whenever you open the project or change a build setting, so it's easy to stage a reserialized version with the markers gone — the hook catches it before it lands. See [CONTRIBUTING.md](../CONTRIBUTING.md) for why the markers matter.

## Renamed from wisescan-ios

The repository, Xcode project, targets, schemes, source folders and Swift module were renamed from wisescan-ios to scan4d-ios in November 2026. The App Store bundle ID and the `wisescandat` URL scheme keep the old name (see [RELEASE.md](RELEASE.md#app-identity)), so a build installs over an older one with all data kept. For an existing clone:

- GitHub redirects the old URLs, but point the clone at the new one: `git remote set-url origin https://github.com/WiseLabCMU/scan4d-ios.git`.
- Open `scan4d-ios.xcodeproj` and pick the `scan4d-ios` scheme. Derived data for the old name stays under `~/Library/Developer/Xcode/DerivedData/wisescan-ios-*` and can be deleted.
- A branch started before the rename: merge main into it. The rename landed as a commit of moves only, so git carries the branch's edits to the moved files. Files the branch added under the old folders are moved into the new ones and reported as conflicts to confirm (`git add` each at its new path); files the branch deleted are reported as deleted by the branch (`git rm` each). Then change `@testable import wisescan_ios` to `scan4d_ios` in any test file the branch added.

## Build (CLI)
```bash
# Device validation (CI / no signing)
xcodebuild -scheme scan4d-ios -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO

# Simulator (local iteration) — list available destinations first
xcodebuild -scheme scan4d-ios -showdestinations | grep 'platform:iOS Simulator'
# Then use a destination from the list, e.g.:
xcodebuild -scheme scan4d-ios -destination 'platform=iOS Simulator,name=iPad Air 13-inch (M4)' build
```
- `generic/platform=iOS` compiles for arm64 — correct for iPad Pro, no device-specific flag needed
- `CODE_SIGNING_ALLOWED=NO` skips provisioning profiles (CI/local validation only)
- For actual device deploy, use Xcode with automatic signing
- Simulator names change across Xcode versions — always verify with `-showdestinations` before scripting builds

## Test
```bash
# Unit tests (scan4d-iosTests) on a simulator; pick a destination from -showdestinations
xcodebuild -scheme scan4d-ios -destination 'platform=iOS Simulator,name=iPad Air 13-inch (M4)' test
# One test class
xcodebuild -scheme scan4d-ios -destination 'platform=iOS Simulator,name=iPad Air 13-inch (M4)' -only-testing:scan4d-iosTests/FeaturePointCloudFileTests test
# Compile the test target without running it (what CI's compile job does not do)
xcodebuild -scheme scan4d-ios -destination 'generic/platform=iOS' build-for-testing CODE_SIGNING_ALLOWED=NO
```
- Unit tests live in `scan4d-iosTests/` (pure logic: gates, file formats, registration, stitching, control plane); UI tests in `scan4d-iosUITests/`.
- CI does not run the tests yet; run them before opening a PR that touches a tested subsystem.

## CI
Every pull request to `main` runs three workflows in `.github/workflows/`:
- `build.yml` compiles the app, unsigned, for `generic/platform=iOS` on a `macos-26` runner with Xcode 26.6 and uploads the xcodebuild log on failure. It is a compile gate only: no tests, no simulator.
- `lint.yml` verifies the `x-release-please-version` markers in `project.pbxproj` and runs `scripts/check-privacy.sh`, the same checks as the local hooks.
- `release-please.yml` maintains the release PR and CHANGELOG from Conventional Commits.

The runner's Xcode lags the lab Macs: code that type-checks on 26.6 has been rejected by Xcode 27 and the reverse is possible. A clean-worktree build on the toolchain you ship with is the only check for that.

## Lint
```bash
swiftlint lint --quiet scan4d-ios/
```
- SwiftLint requires SourceKit from the full Xcode SDK — will crash if `xcode-select` points to CommandLineTools
- Many pre-existing errors exist in `main` (short identifiers in math code, long functions in `FrameCaptureSession`, `MeshPreviewView`, etc.) — when reviewing a branch, diff errors against the `main` baseline:
  ```bash
  # Get baseline
  git stash && swiftlint lint --quiet scan4d-ios/ 2>&1 | grep ": error:" | sort > /tmp/main_errors.txt && git stash pop
  # Get branch errors
  swiftlint lint --quiet scan4d-ios/ 2>&1 | grep ": error:" | sort > /tmp/branch_errors.txt
  # Show only new errors
  comm -23 /tmp/branch_errors.txt /tmp/main_errors.txt
  ```
- Files with pre-existing violations suppressed via file-level `// swiftlint:disable` comments: `FrameCaptureSession.swift`, `ARCoverageView.swift`, `CaptureView.swift`

## Meta Wearables setup

Testing with Meta Ray-Ban glasses (proxy mode, REQ-017) needs a few manual steps. For problems after setup, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md#meta-ray-ban-wearables).

1. **Swift package**
   The project already references the `meta-wearables-dat-ios` package (`https://github.com/facebook/meta-wearables-dat-ios`), and Xcode resolves it when the project opens. Change the package only in Xcode (`File > Packages`): a text edit to `project.pbxproj` for it can corrupt the file.

2. **Meta credentials (optional)**
   Register your `MetaAppID`, `ClientToken` and `TeamID` in the Meta Wearables Developer Center. Keep the real values on your machine only: the privacy guard refuses a staged plist that carries them (see CONTRIBUTING, Credentials). Put them into `Custom-Info.plist` locally without staging the file, or leave them blank to work in the Meta app's developer mode.

3. **Developer mode in the Meta AI app**
   Without registered production credentials:
   - Open the Meta AI companion app (formerly Meta View) on the test iPhone.
   - Go to Settings > Developer Mode and turn it on.
   - When you tap Connect in Scan4D, it deep-links to the Meta AI app; tap Allow on the developer prompt to authorize the local stream.

4. **Checks**
   - **Compilation:** the project compiles cleanly with the package linked.
   - **Pairing:** `DashboardView` lists the glasses once the Meta AI app reports them available.
   - **Hardware trigger:** pressing the capture button on the glasses starts a frame drop into a proxy package (`scan4d_metadata.json`), and the glasses' LED lights.

## Release & TestFlight
See [RELEASE.md](RELEASE.md) — release-please versioning and Fastlane TestFlight distribution.
