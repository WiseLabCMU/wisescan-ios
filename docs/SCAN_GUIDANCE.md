# Scan Guidance Reference

This document lists all pre-scan analysis checks and mid-scan coaching tips. These two systems work together to help users produce high-quality 3D scans.

- **Pre-Scan Analysis** (REQ-030) — optional 360° sweep that checks room conditions *before* recording.
- **Mid-Scan Coaching** (REQ-029) — real-time tips shown *during* recording, based on live scan metrics.

---

## Pre-Scan Space Analysis

Tap **Analyze** (scope icon) near the Record button to begin. The user pans 360° while the app measures ambient lighting, detects room features via RoomPlan, and checks for people using person segmentation. A report modal presents results as pass/warn/alert/skipped cards.

**Source:** [SpaceAnalyzer.swift](../wisescan-ios/SpaceAnalyzer.swift) · [ScanAnalysisReportView.swift](../wisescan-ios/ScanAnalysisReportView.swift)

### Checks

| Check | Condition | Status | Message |
|:------|:----------|:-------|:--------|
| **Lighting** | ≥500 lux | ✅ Pass | "Lighting is good (N lux) — X% well-lit · Y% dim" |
| **Lighting** | 250–500 lux, or >20% dim zones | ⚠️ Warn | "Dim areas detected — scan quality may be reduced. X% well-lit · Y% dim · Z% very dark" |
| **Lighting** | <250 lux majority | 🔴 Alert | "Very low lighting — RGB capture will be poor. Turn on lights for usable scan data." |
| **Lighting** | No data | ⏭️ Skip | "Could not measure lighting" |
| **Screens** | TV detected via RoomPlan | ⚠️ Warn | "TV or monitor detected. Turn off screens to reduce visual artifacts." |
| **Screens** | No TV detected | ✅ Pass | "No screens detected" |
| **Screens** | No RoomPlan data | ⏭️ Skip | "Room detection not available" |
| **Doors** | Doors/openings detected via RoomPlan | ⚠️ Warn | "Door(s) detected. Close doors to avoid trailing incomplete sections." |
| **Doors** | No doors detected | ✅ Pass | "No open doors detected" |
| **Doors** | No RoomPlan data | ⏭️ Skip | "Room detection not available" |
| **People** | Detected, Privacy Filter ON | ⚠️ Warn | "People detected. They will be masked from raw data." |
| **People** | Detected, Privacy Filter OFF | ⚠️ Warn | "People detected. They will appear in raw data. Tip: Enable the Privacy Filter." |
| **People** | Not detected | ✅ Pass | "No people detected" |

### How It Works

- **Lighting** uses ARKit's `lightEstimate.ambientIntensity` (lux). Each 1° yaw bucket is tagged with a lux tier on first visit; the report shows zone percentages. Thresholds are in `AppConstants` (`analysisAmbientLightAlertThreshold` = 250, `analysisAmbientLightWarnThreshold` = 500).
- **Screens / Doors** use a temporary RoomPlan session started for analysis (regardless of the Semantic Labeling toggle). The session is stopped and outlines cleared when analysis ends.
- **People** use ARKit's `personSegmentationWithDepth` stencil. During analysis, segmentation is temporarily enabled even when the Privacy Filter is OFF, then restored on stop.
- The 360° sweep tracks yaw coverage across ~330 buckets. A 30s timeout fires if coverage isn't reached.

---

## Mid-Scan Coaching

Real-time tips during recording, evaluated at ~1 Hz by the `ScanCoach` rules engine. The highest-priority active tip is shown in a color-coded bar above the bottom HUD. Tips have anti-nag behavior: per-tip cooldowns, auto-dismiss timers, and suppression after 2 manual dismissals.

**Settings toggle:** Scan Coaching (default ON) — suppresses GUIDANCE and INFO tips; CRITICAL and WARNING always evaluate.

**Source:** [ScanCoach.swift](../wisescan-ios/ScanCoach.swift) · [CoachBarView.swift](../wisescan-ios/CoachBarView.swift)

### Tips by Priority

#### 🔴 CRITICAL — stays until resolved

| Tip ID | Condition | Message |
|:-------|:----------|:--------|
| `critical.excessiveMotion` | Tracking limited: excessive motion | "⚠️ Hold steady — excessive motion detected" |
| `critical.insufficientFeatures` | Tracking limited: insufficient features | "⚠️ Hold steady — not enough visual features" |
| `critical.notAvailable` | Tracking not available | "⚠️ Tracking unavailable — hold device steady" |

#### 🟠 WARNING — auto-dismiss 8s, no cooldown

| Tip ID | Condition | Message |
|:-------|:----------|:--------|
| `warning.fastMotion` | Motion blur active (fast motion) | "⚠️ Slow down — moving too fast" |
| `warning.atCapacity` | Session at capacity | "Session at capacity — save now to avoid quality loss" |
| `warning.nearCapacity` | Session near capacity | "Approaching session limits — consider saving" |

#### 🔵 GUIDANCE — auto-dismiss 6s, 30s cooldown (suppressed when coaching OFF)

| Tip ID | Condition | Message |
|:-------|:----------|:--------|
| `guidance.scanWalls` | Early scan, <8 anchors, <3m spatial extent | "🏠 Scan all 4 walls quickly for layout context" |
| `guidance.systematicSweep` | Early scan, erratic movement pattern (<0.3 ratio) | "↔️ Start from one wall, sweep to the opposite" |
| `guidance.moveCloser` | Mid-scan, <200 faces/anchor (coarse geometry) | "🔍 Move closer to capture fine details" |
| `guidance.varyHeight` | Mid-scan, height variance <0.02 (flat scanning) | "↕️ Try scanning from a different height" |
| `guidance.semantic.scanFloor` | Semantic ON, walls detected but no floor | "🪟 Walls detected, try scanning the floor" |
| `guidance.semantic.scanObjects` | Semantic ON, ≥3 surfaces but 0 objects | "🛋️ Don't forget furniture — scan objects up close" |
| `guidance.semantic.lowerAngle` | Semantic ON, floor detected, <3 objects | "🔽 Try scanning from a lower angle for floor objects" |

#### 🟢 INFO — auto-dismiss 5s, 60s cooldown (suppressed when coaching OFF)

| Tip ID | Condition | Message |
|:-------|:----------|:--------|
| `info.goodCoverage` | Mid-scan, ≥15 anchors, capacity <50% | "⭐ Coverage looking good!" |
| `info.considerFinishing` | >60s, mapped, ≥20 anchors, mesh growth slowed | "✅ Great coverage — consider finishing" |

### Priority Behavior

| Priority | Color | Auto-Dismiss | Cooldown | Settings Toggle |
|:---------|:------|:-------------|:---------|:----------------|
| CRITICAL | Red | Never (condition-driven) | None | Always active |
| WARNING | Orange | 8s | None | Always active |
| GUIDANCE | Indigo | 6s | 30s | Suppressed when OFF |
| INFO | Green | 5s | 60s | Suppressed when OFF |

Anti-nag: tips are suppressed after 2 manual dismissals (swipe-up) per session. Cooldown timers are in [AppConstants.swift](../wisescan-ios/AppConstants.swift).
