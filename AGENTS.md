# Agent Guide

Orientation for agents (and humans) working in this repo. Detailed docs live in the files below — this file is just the index.

## Build, lint & release
[docs/BUILDING.md](docs/BUILDING.md) — Xcode toolchain setup, CLI build (device + simulator), SwiftLint usage, and the `main`-baseline diffing workflow for pre-existing violations.
[docs/RELEASE.md](docs/RELEASE.md) — release-please versioning + Fastlane TestFlight.

## Conventions & development rules
[CONTRIBUTING.md](CONTRIBUTING.md) — mandatory rules for all contributors, **including agents**: commit format, code style (SwiftData enums, `@Observable`/simd), AR session lifecycle, privacy patterns, performance/VIO invariants, and the **stitching / scan-linking implementation contract**.

## Architecture & requirements
[REQUIREMENTS.md](REQUIREMENTS.md) — single source of truth for features, architecture, and implementation status.
[docs/design/Scan4D_Architecture.md](docs/design/Scan4D_Architecture.md) — design rationale (Backend-First philosophy, large-space stitching strategies).

## Troubleshooting
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — known issues and recovery steps (Meta Wearables SDK, hardware quirks).
