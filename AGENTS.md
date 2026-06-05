# Agent Guide

Orientation for agents (and humans) working in this repo. Detailed docs live in the files below — this file is just the index.

## Start here
- [README.md](README.md) — what Scan4D is, device-support matrix, features, architecture overview, export formats, quick start.
- [REQUIREMENTS.md](REQUIREMENTS.md) — single source of truth for features, architecture, data model, and implementation status (REQ-### entries).

## Conventions & development rules
- [CONTRIBUTING.md](CONTRIBUTING.md) — mandatory rules for all contributors, **including agents**: commit format, code style (SwiftData enums, `@Observable`/simd), AR session lifecycle, privacy patterns, performance/VIO invariants, and the **stitching / scan-linking implementation contract**.

## Build, lint & release
- [docs/BUILDING.md](docs/BUILDING.md) — Xcode toolchain setup, CLI build (device + simulator), SwiftLint usage, and the `main`-baseline diffing workflow for pre-existing violations.
- [docs/RELEASE.md](docs/RELEASE.md) — release-please versioning + Fastlane TestFlight.
- [CHANGELOG.md](CHANGELOG.md) — generated release history (release-please; Conventional Commits).
- [docs/APPSTORE.md](docs/APPSTORE.md) — App Store / TestFlight listing copy and submission notes.

## Architecture & design
- [docs/design/Scan4D_Architecture.md](docs/design/Scan4D_Architecture.md) — design rationale (Backend-First philosophy, large-space stitching strategies).
- [docs/design/DESIGN.md](docs/design/DESIGN.md) — original UI/UX design spec.
- [docs/design/voxel-accumulated-point-cloud.md](docs/design/voxel-accumulated-point-cloud.md) — VR voxel point-cloud accumulation design.

## Export formats & data contracts
- [schemas/README.md](schemas/README.md) — export archive structure and JSON schemas for every persisted/exported file: `scan4d_metadata.json`, `stitching.json` (spatial links), `transforms.json`, Polycam `cameras/*.json`, `mesh_info.json`. JSON Schema files live alongside it in [schemas/](schemas/).

## Privacy & troubleshooting
- [docs/PRIVACY.md](docs/PRIVACY.md) — privacy model (person-segmentation blur, on-device processing, what leaves the device).
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — known issues and recovery steps (Meta Wearables SDK, hardware quirks, relocalization/stitching alignment).
