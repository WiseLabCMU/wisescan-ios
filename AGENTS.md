# Agent Guide

Orientation for agents (and humans) working in this repo. Detailed docs live in the files below; this file is the index plus the handful of rules that are easy to get wrong.

## Non-negotiables (details in CONTRIBUTING.md)
- Conventional Commits for every commit and PR title. Never `BREAKING CHANGE` in a body and never a `!` type: release-please would bump the major version, and that is the maintainer's call.
- Icons yes, emoji no: no emoji characters inside text (docs, comments, commits, PR text, UI strings), because their rendering and parsing is not universal and the first one laid out in a session has cost the main thread seconds. In the app, attach a graphic next to the text (`Image(systemName:)`, `CoachTip.icon`) instead.
- `#NN` only when it names a real GitHub issue or PR.
- Link a file in this repo by a path relative to the linking file (`../../scan4d-ios/VoxelGrid.swift`). Name a file outside it by its repo: a GitHub link when the repo is public, otherwise the repo's name and "(private, not in this repo)". Never a local path (`file:///Users/...`, `/Users/...`, `~/git/...`): it opens only on the machine that wrote it.
- `project.pbxproj` carries two `/* x-release-please-version */` markers that Xcode strips on save. The pre-commit hook and CI both refuse a commit without them; run `./scripts/install-hooks.sh` once after cloning.
- Never put a real server URL or hostname in the repo (code, tests, docs, commit messages, PR text): use example URLs (`https://example.com` and its subdomains). The app ships with the Scan4D server setting empty; a real URL comes only from what a user enters in the Server tab.
- Never commit debug-only file-sharing Info.plist keys, raw capture artifacts, vendor SDK binaries, or credentials (Meta `MetaAppID` / `ClientToken` values, any SDK app secret). The privacy guard (`scripts/privacy-guard.sh`) is the pattern library the hook and CI share, and it refuses all of these.
- The repo was renamed from wisescan-ios in November 2026. Two identifiers keep the old name on purpose, never rename them: the bundle ID `edu.cmu.wiselab.wisescan-ios` (an App Store app's bundle ID can never change; a new one is a new app, and testers would lose their scans, settings and stored password) and the Meta glasses URL scheme `wisescandat` (the Meta AI app returns to the app by it). See docs/RELEASE.md.
- Rewrite only your own unpushed commits; never rebase, amend, or force-push someone else's.
- Documentation ships with the feature: a README feature bullet (at most two sentences; detail goes in REQUIREMENTS), a REQ entry and Source File Index rows, the App Store copy, PRIVACY.md when data handling changes, the in-app user guide, and this index.
- A new Developer Mode option (Settings) goes into `AppConstants.developerOptionDefaults`, key and default, in the same change. Restore Default Developer Options and turning Developer Mode off reset only that list, so an option missing from it keeps its bench value in production use.

## Start here
- [README.md](README.md) — what Scan4D is, device-support matrix, short feature list, export formats, backend repos, quick start.
- [REQUIREMENTS.md](REQUIREMENTS.md) — single source of truth for features, architecture, the Source File Index (every source file by area), data model, and implementation status (REQ-### entries, including which are "device test pending").

## Conventions & development rules
- [CONTRIBUTING.md](CONTRIBUTING.md) — mandatory rules for all contributors, **including agents**: commit format, code style (SwiftData enums, `@Observable`/simd), AR session lifecycle, privacy patterns, performance/VIO invariants, and the **stitching / scan-linking implementation contract**.

## Build, test, CI & release
- [docs/BUILDING.md](docs/BUILDING.md) — toolchain (Xcode 26.6+, iOS 18.0 target), CLI build for device and simulator, running the unit tests, what CI does and does not check, SwiftLint and the `main`-baseline diff.
- CI on every PR: `build.yml` compiles the app unsigned on macos-26 / Xcode 26.6 (a compile gate, no tests); `lint.yml` checks the release-please markers and the privacy guard; `release-please.yml` maintains the release PR. Lab Macs run Xcode 27, which has rejected code CI accepted; build from a clean worktree on the shipping toolchain before you call a branch green.
- Tests: `scan4d-iosTests/` (gates, file formats, registration, stitching, control plane) and `scan4d-iosUITests/`. CI does not run them; you do.
- [docs/RELEASE.md](docs/RELEASE.md) — release-please versioning + Fastlane TestFlight.
- [CHANGELOG.md](CHANGELOG.md) — generated release history (release-please; Conventional Commits).
- [docs/APPSTORE.md](docs/APPSTORE.md) — App Store / TestFlight listing copy and submission notes.

## Architecture & design
- [docs/design/Scan4D_Architecture.md](docs/design/Scan4D_Architecture.md) — the historical plan: design rationale (Backend-First philosophy, anchoring strategy, large-space stitching strategies). The backend it sketches became the control plane in `scan4d-server`.
- [docs/design/DESIGN.md](docs/design/DESIGN.md) — original UI/UX design spec.
- [docs/design/fix-localization-plan.md](docs/design/fix-localization-plan.md) — the save-pipeline split (RAW-persist vs derived artifacts, "DECISION 3") that `ScanPostprocessor` implements.
- [docs/design/capture-quality-triage.md](docs/design/capture-quality-triage.md) — device-test triage for the hi-res keyframe work: what was verified and the watch items (thermal ceiling, teardown stalls, OS interruptions corrupting the map).
- [docs/design/voxel-accumulated-point-cloud.md](docs/design/voxel-accumulated-point-cloud.md) — VR voxel point-cloud accumulation design.
- [docs/design/still-source-360.md](docs/design/still-source-360.md) — the 360° still source: `StillSource` seam, Ricoh Theta Z1/X rig, calibration, cube-map export, field journal; the Insta360 X6 (OSC, no SDK) is tracked in issues #99 and #100.
- [docs/design/capture-modes.md](docs/design/capture-modes.md) — room scan vs focus scan (a partial scan of one box-shaped region): the shared foundation (capture state, session roles, exposure policy), the region and its frames, detail levels, automatic room stills, region import; decisions and phases.
- [docs/design/export-consolidation.md](docs/design/export-consolidation.md) — why the app exports one superset (Scan4D) and the Nerfstudio and flame3d layouts are made on the server; what it cost, compatibility, and the equivalence evidence.
- [docs/design/sync-bundle.md](docs/design/sync-bundle.md) — sync sends the whole scan as one bundle (plus the map's JSON and a RoomPlan preview), the server ingests it with a Postgres job queue, and Share is for files other systems read; what goes away and the phases.
- [docs/design/splat-reconstruction.md](docs/design/splat-reconstruction.md) — Gaussian-splat training from the Nerfstudio dataset (LichtFeld/Nerfstudio): findings, recommended downstream pipeline, and on-app capture recommendations.
- [docs/SCAN_GUIDANCE.md](docs/SCAN_GUIDANCE.md) — complete reference of pre-scan analysis checks (lighting, screens, doors, people) and mid-scan coaching tips (critical/warning/guidance/info) with conditions and messages. Keep it identical to the strings in `ScanCoach.swift`.

## Export formats, data contracts & sibling repos
- [schemas/README.md](schemas/README.md) — export archive structure and JSON schemas for every persisted/exported file: `scan4d_metadata.json`, `stitching.json` (spatial links), `transforms.json`, Polycam `cameras/*.json`, `mesh_info.json`, plus the binary sidecars `arkit_features.bin` and `sweep_coverage.bin`. JSON Schema files live alongside it in [schemas/](schemas/).
- `scan4d-server` (private sibling repo) — the control plane the app syncs its inventory with (REQ-038): device registry, base/tip maps, scans, links, gone-marking, each scan's bundle (the whole scan, unpacked by its job queue), tasks, events, the web app, and Prefect for the flows. Its README is the design and the API contract; the app side is `ControlPlaneSync.swift` / `ControlPlaneManifest.swift` / `ControlPlaneClient.swift`.
- `scan4d-flows` (private sibling repo, the `prefect-server` folder) — the Prefect flows deployed into that stack. Everything made from the Scan4D export happens there: the Nerfstudio dataset in `scan4d-normalize`, the flame3d bundle in `scan4d-flame3d`, both through `scan4d-convert`; splat training in `scan4d-splat`; also `eagle-splat` and `spark-build-lod`. The app exports one superset, Scan4D; a new layout for another tool is a flow there, not an app export.
- [wisescan-upload](https://github.com/WiseLabCMU/wisescan-upload) — HTTP/3 upload gateway (Caddy + VersityGW S3) where app builds before sync bundles uploaded their exports; the app no longer sends anything there.
- [wisescan-ingestion](https://github.com/WiseLabCMU/wisescan-ingestion) — NATS JetStream stack for time-series binary streams; not on the export path.
- `wiselab-scan` (sibling checkout, not on GitHub) — platform-wide architecture notes referenced from REQUIREMENTS.md.

## In-app user guide (documentation written in Swift)
- [scan4d-ios/UserGuideView.swift](scan4d-ios/UserGuideView.swift) — the in-app **User Guide** (Settings → User Guide & Documentation): the user-facing walkthrough (capture → save → rescan/link → export), scan-technique tips, troubleshooting for the sync and warning badges on locations and scan cards ([scan4d-ios/UserGuideStatusIcons.swift](scan4d-ios/UserGuideStatusIcons.swift)), export-format descriptions, supported wearables, and recommended viewers. Treat it as **documentation that happens to live in SwiftUI**: when user-facing workflows, scan suggestions, or export formats change, update it in the same change set, exactly as you would [README.md](README.md), [REQUIREMENTS.md](REQUIREMENTS.md), and [docs/APPSTORE.md](docs/APPSTORE.md). Its scan tips should stay consistent with [docs/SCAN_GUIDANCE.md](docs/SCAN_GUIDANCE.md).

## Field testing & diagnostics
- [docs/developer-tools.md](docs/developer-tools.md) — the on-device developer/field-test surface: Performance Diagnostics and what each `[perf]` log prefix means, the diagnostics log export (and its two iOS-imposed limits), simulation toggles, the sweep-coverage readout, the Color-from-360°-Faces pose probe, the BLE bench, and calibration provenance in sidecars.
- [docs/testing/](docs/testing/) — dated device test plans. A REQ marked "device test pending" is closed by a dated file here recording the device, build, and result; [2026-07-30-360-branch-test-plan.md](docs/testing/2026-07-30-360-branch-test-plan.md) is the template.
- [tools/scan4d-to-nerfstudio/README.md](tools/scan4d-to-nerfstudio/README.md) — mesh-rendered priors, hole filling, pose refit and depth masks for splat training; the verdicts are in the splat design doc.
- [tools/ar-capture-splat/README.md](tools/ar-capture-splat/README.md) — focus capture to a box-cropped reconstruction (ingest, SfM, masks, finalize; Dockerfile).
- [tools/scan4d-convert/README.md](tools/scan4d-convert/README.md) — one command from a Scan4D export to a Nerfstudio dataset or a flame3d bundle on anyone's machine, as the server's `scan4d-convert` does; `normalize.py` here is the original the flows copy.
- [tools/scan4d-to-flame3d/README.md](tools/scan4d-to-flame3d/README.md) — converter from a Scan4D capture's Nerfstudio dataset to a flame3d-core input bundle (3D segmentation / semantic search): the bundle's contract, the copy the server's `scan4d-flame3d` flow runs, and `--verify` for checking any bundle.
- [tools/rigcal-ab/README.md](tools/rigcal-ab/README.md) — Mac-side offline solver harness (ffmpeg + numpy): re-run the photometric rig solve against exported `staging_*` bundles, A/B cost functions; carries the edge-vs-photometric verdict behind solver v15.

## Privacy & troubleshooting
- [docs/PRIVACY.md](docs/PRIVACY.md) — privacy model (person-segmentation blur, on-device processing, what leaves the device). It is the policy linked from App Store Connect; it must describe every third-party SDK and every network destination the app actually has.
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — known issues and recovery steps (Meta Wearables SDK, hardware quirks, relocalization/stitching alignment).
