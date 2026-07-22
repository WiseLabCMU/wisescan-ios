# Design: Pluggable Still Sources & 360° Camera Rig

**Status:** Proposed (future feature — depends on the voxel coverage grid)
**Branch context:** builds on `feat/capture-quality` (REQ-031: hi-res stillness keyframes)
**Author intent:** captured 2026-07-15/16 design discussion

## Motivation

REQ-031 captures sharp stills from the device camera at stillness points, and the
planned voxel coverage grid will track *which voxels each still covers and from which
directions*. A pinhole still covers a narrow frustum, so full splat-quality coverage of a
voxel requires **multiple stills from multiple angles** — the user must orbit every
surface.

A 360° camera inverts that economics: **one equirectangular still per voxel position**
covers every direction at once. Mounted ~1m above the phone on a rod, it also sees over
furniture and captures ceiling/floor detail the phone operator rarely sweeps.

This design makes the still source pluggable:

- **Onboard camera (default)** — the existing `captureHighResolutionFrame` pipeline.
  No hardware, no calibration, per-frame pinhole intrinsics. Unchanged behavior.
- **External 360° camera (alternative)** — a handheld rig: iPhone running Scan4D
  clipped at the base, telescoping rod extending the 360° camera ~1m vertically.
  Output: 2:1 equirectangular stills at ≥4K (candidate cameras deliver 7K–11K natively).

## Hardware rig

```
        (360° camera)  ← equirect stills, ~1m above phone
             |
             |  telescoping rod (rigid when extended; lever arm L)
             |
      [ iPhone clip ]  ← Scan4D: ARKit pose, LiDAR mesh, voxel grid, trigger UI
             |
        (hand grip)
```

Rig invariants the software depends on:

- The rod is **rigid and repeatable** when extended (detent or twist-lock at a fixed
  length) so the phone→camera transform is a constant per rig profile.
- The camera mount is keyed (no free rotation) so yaw offset is also constant.
- Rod sway is the main pose-noise source — the existing stillness gate (device must be
  confirmed still before a keyframe fires) is what makes the lever-arm pose usable.

## Candidate cameras & viability assessment

| | Ricoh Theta Z1 | Ricoh Theta X | Insta360 X3 / X4 |
| :--- | :--- | :--- | :--- |
| Still resolution | ~23MP equirect (6720×3360, 2:1) + RAW DNG | ~60MP equirect (11008×5504, 2:1) | 72MP stills (X3 and X4) |
| Sensor | dual 1.0-type (best low-light of the line) | dual 1/2" | dual 1/2" (X3) / dual 1/2" 8K-video class (X4) |
| Control API | OSC (Open Spherical Camera) Web API v2.1 over WiFi; BLE wake/trigger; USB (PTP) | same OSC Web API v2.1 family; BLE; USB | proprietary protocol over BLE + WiFi AP |
| iOS SDK | **`theta-client`** — Ricoh's official open-source multiplatform SDK (iOS/Kotlin MP/React Native) | same `theta-client` SDK | official Insta360 mobile SDK — application-gated (requires developer agreement) |
| Still format | in-camera stitched equirect | in-camera stitched equirect | native dual-fisheye; stitching via SDK/app (extra pipeline step to reach equirect/cube) |
| Plugin system | yes (Android-based internals, installable plugins) | yes | no (closed firmware) |
| Notes | discontinued-risk to check (Z1 availability has fluctuated); proven in photogrammetry rigs | fastest stills-per-minute of the line; heavier | SDK access + dual-fisheye stitching are the two viability risks to resolve first |

Assessment criteria for each (fill in during the viability spike):

1. **Trigger latency** — BLE/OSC `takePicture` round-trip; can it keep up with a
   ~1 pause per 5–10s scanning cadence?
2. **Transfer time** — 20–70MP JPEG over WiFi per still; is in-situ download viable or
   post-process only?
3. **SDK maturity on iOS** — `theta-client` covers both Ricohs (raw OSC HTTP is a
   fallback since OSC is a published Google spec); Insta360 requires SDK-agreement
   approval plus a stitching step, so its go/no-go hinges on both.
4. **Metadata quality** — per-still gyro/level (zenith) data, timestamps, exposure info.
5. **Cost, weight, battery life** on a handheld rig.

### Measured on device (spike — Theta X, `feat/still-source-360`)

First Wi‑Fi-OSC numbers from the Dashboard card ("Test Shutter" + "Download & Preview"):

- **Trigger** (`camera.takePicture` round trip to `done`, over OSC HTTP): confirmed working.
- **Transfer**: ~4.5 MB JPEG downloaded in ~1100 ms ≈ **~4.1 MB/s** over the camera AP.

Read: at ~4 MB/s a full-resolution 60MP still (~15–20 MB) would take **~4–5 s** to
transfer — consistent with the "2–6 s per still" estimate above, which points to
**post-process mode as the default** and makes in-situ transfer viable only for smaller /
lower-res captures. Caveat: a 4.5 MB file implies the camera was **not** at max still
resolution — confirm the resolution setting before treating transfer time as final
(max-quality stills transfer roughly 4× longer).

## Architecture: `StillSource` abstraction

Introduce a protocol seam where `FrameCaptureSession` currently calls
`requestHighResolutionKeyframe`:

```swift
protocol StillSource {
    var kind: StillSourceKind { get }          // .onboard, .theta_z1, .theta_x, ...
    var isReady: Bool { get }                  // connected + configured
    /// Trigger a still at the current stillness point. Completion delivers either
    /// image data + metadata now (in-situ) or a claim ticket resolved at post-process.
    func captureStill(at pose: simd_float4x4, timestamp: TimeInterval,
                      completion: @escaping (StillResult) -> Void)
}

enum StillResult {
    case image(StillImage)                     // pixel data + resolved pose + model
    case deferred(StillTicket)                 // matched to a file during post-process
    case failure(Error)
}

struct StillImage {
    let data: Data                             // JPEG (equirect or pinhole)
    let width: Int, height: Int
    let cameraModel: StillCameraModel          // .pinhole(intrinsics) | .equirectangular
    let cameraToWorld: simd_float4x4           // resolved pose (rig transform applied)
    let isKeyframe: Bool                       // always true for stills
    let sourceKind: StillSourceKind
}
```

- `OnboardStillSource` wraps the existing hi-res path (retry budget, watchdog,
  admission-gated bookkeeping all stay).
- `Theta360StillSource` implements OSC trigger + (in-situ or deferred) download.
- The stillness gate, reticle, shutter feedback, and voxel coverage marking all sit
  **above** the seam and work identically for both sources — with one difference:

### Coverage marking for 360° stills

A pinhole keyframe marks voxels via a frustum test. An equirect still marks **all voxels
within radius `r` of the camera center that pass an occlusion check** (mesh/depth raycast
from the elevated camera position — the voxel grid design already includes depth-tested
visibility). Because the camera sits ~1m up, its visibility raycasts use the *camera's*
position, not the phone's — it legitimately sees over obstacles the phone can't.

## Communication & capture flow

**Trigger transport: BLE preferred** (sub-second, no WiFi captivity, phone keeps its
network); **captive WiFi is the accepted fallback** and is required anyway for image
transfer (`NEHotspotConfiguration` joins the camera's AP programmatically; ARKit needs
no network during capture, but upload must wait until the scan ends).

Two supported transfer modes (per-session setting):

1. **In-situ** — on stillness confirmation: trigger (BLE if available, else OSC over
   WiFi) → poll status → download JPEG over WiFi → run through the normal save pipeline
   with resolved pose. Pros: immediate coverage feedback (voxels clear in the overlay as
   you scan). Cons: 2–6s per still of WiFi transfer during the scan.
2. **Post-process** — BLE trigger only; record a `StillTicket`
   {trigger timestamp, resolved rig pose, sequence number}. After the scan, download the
   camera's session images and match tickets → files by timestamp/sequence. Pros: fast
   capture cadence, no WiFi transfer mid-scan. Cons: coverage overlay must mark voxels
   *optimistically* at trigger time and reconcile failures afterward.

Recommendation: build **post-process first** (simpler, robust to transfer hiccups),
add in-situ once the calibration and matching pipeline is trusted.

## Pose & calibration plan

The hard problem. The still's pose must land in the **same ARKit world frame** as the
mesh, sweep frames, and voxel grid.

**Pose composition:**
`T_world→360cam = T_world→phone (ARKit, at trigger timestamp) × T_phone→360cam (rig extrinsic)`

**Rig extrinsic calibration (per rig profile, stored in settings):**

1. **Mechanical prior** — measured rod length + mount geometry gives `T_phone→360cam`
   to a few cm / few degrees.
2. **Refinement capture** — a one-time guided calibration scan in a feature-rich room:
   capture N 360° stills at stillness points alongside the LiDAR mesh + phone keyframes,
   then solve the rig transform that best registers the equirect stills to the mesh
   (feature correspondences between equirect projections and phone keyframes/mesh —
   effectively a hand–eye calibration with the ARKit trajectory as ground truth).
3. **Validation** — reproject mesh edges into the equirect still; report residual error
   in-app; refuse to enable the source above a threshold.

**Per-still corrections:**

- **Timing** — trigger→exposure latency is nonzero and camera-specific; measure it in the
  calibration step and sample the ARKit pose at `t_trigger + Δt_exposure` (the stillness
  gate makes this forgiving — the pose barely moves during a valid capture).
- **Orientation source** — Theta cameras apply internal zenith (level) correction using
  their own IMU. **Disable in-camera zenith correction** and treat orientation as fully
  determined by the rig transform, OR keep it and calibrate only position + yaw. Pick one
  during the spike; mixing both silently double-corrects roll/pitch.
- **Rod sway** — reject stills whose trigger window shows angular velocity above the
  stillness threshold; optionally cross-check the camera's own gyro metadata.

**Calibration reuse policy (rig-type dependent):**

- **Telescoping rigs**: assume the extrinsic does NOT survive collapse/extend cycles —
  default to a quick re-calibration (or at least a validation capture) at the start of
  each session.
- **Fixed rigs**: persist the calibration profile and reuse across sessions.
- The rig profile in settings records the rig type and a **user-reported repeatability
  rating**; that rating drives whether the app demands re-calibration, suggests
  validation, or silently reuses the stored transform. Calibration residuals from each
  validation are logged into scan metadata so drift is visible downstream.

## Rod stillness metric

Phone stillness is not rig stillness: a 1m lever arm turns small hand rotations into
large camera-position sway, and the rod itself oscillates after movement stops. The
stillness gate gains a **rig mode**:

- **Tighter angular threshold** — position error at the camera ≈ `L × angular velocity`,
  so with `L ≈ 1m` the angular stillness threshold must shrink to keep camera-position
  noise comparable to the onboard case (e.g. 0.1 rad/s at the phone = ~10cm/s at the
  camera head).
- **Sway settle detection** — after motion stops, the rod rings at a few Hz. Track the
  recent pose window (the session already keeps `recentTransforms`) and require the
  oscillation amplitude projected through the lever arm to fall below a camera-position
  threshold (e.g. <1cm peak) for the confirmation window, not just instantaneous
  velocity.
- **Cross-check with camera IMU metadata** where available (Theta stills embed
  gyro/level data): large disagreement between predicted and reported camera orientation
  at exposure time flags a sway-corrupted still for rejection/retry.
- **Reticle affordance** — in rig mode the reticle reflects *rod* steadiness (the
  composite metric above), so the ring fills more slowly and honestly than phone-only
  stillness would suggest.

## Export: cube map, bottom face discarded

Rather than exporting raw equirectangular frames, the export pipeline **reprojects each
360° still into a cube map and discards the bottom face**, which is dominated by the
operator, hand grip, and rod:

- Each remaining face (front/back/left/right/up) is a synthetic **pinhole camera with
  exact 90° FOV intrinsics** and an orientation offset from the still's pose — so
  downstream tools see ordinary pinhole frames and the equirectangular camera-model
  problem disappears from the data contract entirely.
- Faces are emitted as regular frames in `transforms.json` / Polycam cameras (five
  entries per 360° still) with `is_keyframe: true`.
- The raw equirect image can optionally be archived in the bundle for reprocessing, but
  it is not part of the training contract.
- Face resolution derives from the source still (e.g. a 6720×3360 Z1 equirect yields
  ~1680×1680 faces; the Theta X and Insta360 yield proportionally more).

## Export & schema changes

- `transforms.json` frames: cube-face frames carry standard per-frame pinhole intrinsics
  (already supported since REQ-031), `is_keyframe: true`, plus new
  `still_source: "onboard" | "theta_z1" | "theta_x" | "insta360_x3" | "insta360_x4"`
  and `cube_face: "front" | ... | "up"` for provenance.
- `scan4d_metadata.json`: rig profile (rig transform matrix, rod length, rig type
  fixed/telescoping, camera model + firmware, calibration residual, transfer mode).
- Schemas in `schemas/` updated accordingly (they are the data contract — see
  CONTRIBUTING).

## Privacy

360° stills capture *everything*, including people behind the operator that the phone's
forward-facing privacy stencil never saw. The cube-map export makes this tractable: each
exported face is an ordinary pinhole image, so the existing Vision-fallback person
blur runs per-face with no equirectangular distortion issues (detection on raw equirect
is unreliable near the poles). Discarding the bottom face also removes most operator
imagery by construction. If the raw equirect is archived in the bundle, it must receive
the same per-face-derived masks before leaving the device. This must land **before**
any 360° source ships — it is a hard privacy invariant (no unblurred person leaves the
device; docs/PRIVACY.md).

## Phasing

| Phase | Deliverable | Gate |
| :--- | :--- | :--- |
| P0 | Voxel coverage grid (prerequisite, already on the roadmap) | coverage marking is depth-tested |
| P1 | `StillSource` seam refactor; onboard source behind it (no behavior change) | existing device tests still pass |
| P2 | Viability spike: Theta Z1 + Theta X via `theta-client`/OSC; identify & assess the third camera; measure trigger/transfer latency | written go/no-go per camera |
| P3 | Post-process 360° pipeline: BLE/OSC trigger, ticket matching, rig calibration flow, equirect export + privacy cube-face blur | calibration residual under threshold on a real rig |
| P4 | In-situ transfer + live coverage feedback; settings UI for source/rig profiles | scan cadence not degraded vs post-process |

## Open questions

- Insta360 SDK access: how long does the developer-agreement approval take, and does the
  iOS SDK expose still trigger + dual-fisheye download + on-device stitching, or only a
  subset?
- Cube-face resolution/overlap: is 90° FOV per face optimal for splat training, or do
  slightly-overlapping faces (e.g. 100° FOV) help feature matching at face seams?
- Where does dual-fisheye → equirect stitching run for Insta360 (on device, in the
  camera, or in wisescan-ingestion)?
- Trigger→exposure latency variance per camera: constant enough to calibrate once, or
  does it need per-still estimation from camera timestamps?
- How does the coverage overlay communicate "covered by 360° still pending transfer"
  (post-process mode) vs "confirmed on device" — a third visual state or optimistic
  clear with post-scan reconciliation report?
