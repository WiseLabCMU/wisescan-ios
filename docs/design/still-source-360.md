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

### Measured on device (spike — Theta X, firmware 2.92.0)

Wi‑Fi-OSC numbers from the Dashboard card, at both still resolutions:

| Still resolution | Trigger (`takePicture`→`done`) | JPEG size | Transfer | Rate |
| :--- | :--- | :--- | :--- | :--- |
| 5504×2752 (~15 MP) | ~1.9 s | ~4.3 MB | ~1.1 s | ~3.9 MB/s |
| 11008×5504 (~61 MP) | ~3.3 s | ~10.5–11.5 MB | ~2.2–2.6 s | ~4.5 MB/s |

Reads:

- The AP link is the transfer bottleneck at a steady **~4.5 MB/s** regardless of size.
- At **max 61 MP the per-still cost is ~3.3 s trigger + ~2.5 s transfer ≈ ~6 s** done
  in-situ sequentially — the top of the "2–6 s" estimate. So **post-process mode is the
  default for 61 MP**; in-situ live transfer is only comfortable at the lower resolution.
- Important for the rig: the **~3.3 s is the camera's capture + in-camera-stitch time**,
  not transfer — BLE-trigger + deferred download can't hide it. The rod must be held
  steady for ~3.3 s per 61 MP shot, which the stillness / sway-settle gate must
  accommodate (see "Rod stillness metric").

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

**Camera-agnostic contract (adopted 2026-07-24, ahead of the seam refactor):** the on-disk
/export payload is generalized so supporting more 360° cameras never changes the data
format — stills live in `raw_data/equirect_stills/` as `still_NNNN.{JPG,json}`, and
the DEVICE identity travels in the sidecar's `still_source` field (the camera's reported
model string, e.g. "RICOH THETA X"), never in path names. Code identity follows at the
seam refactor: today's `ThetaCameraManager` is really an **OSC-family** manager (OSC is a
published spec covering the Ricoh line and other compliant cameras) and renames
accordingly when it moves behind `StillSource`; a non-OSC camera (Insta360's proprietary
SDK + dual-fisheye stitching) becomes its own `StillSource` implementation writing the
same contract.
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

### Calibration method: markerless mesh-edge reprojection (decision, 2026-07-28)

No AprilTags, no markers in the scene. The solver aligns **LiDAR mesh edges** (already in
the ARKit world frame) with **detected edges in the 360° equirect stills** — a hand-eye
calibration where ARKit's trajectory is ground truth and the rich structural data from
LiDAR provides the correspondences. The equirect's full-sphere view guarantees many edge
correspondences (walls, door frames, furniture) regardless of phone orientation.

**Why not markers?** AprilTags in the scan area would need privacy-filter handling and
pollute the very textures we're trying to capture cleanly. Tags on the rig itself could
work but add hardware complexity and limit which rigs are supported. Natural-feature
calibration using the LiDAR mesh the app already builds requires no extra hardware and
works in any feature-rich indoor environment.

### Solver: 5 DOF, on-device (Accelerate/simd)

With the Theta's zenith correction handling roll/pitch (validated for Theta X), the
unknowns are a rigid offset plus a heading:

1. **`offsetPhone`** (3) — the phone-camera→360°-lens offset **in the phone's own frame**
   (ARKit camera axes: +x right, +y up, −z view direction). The rod runs along −x̂, so a
   0.72 m rig is about `(-0.72, 0, 0)`.
2. **`yaw`** — rotation around the vertical axis
3. **`pitch_residual`** — small pitch correction for imperfect zenith compensation

The offset is in the PHONE's frame because that is what "rigid" means for a rig bolted to
the phone — it rotates with the device. The original 4-parameter form stored a world-frame
pair (`dy` along gravity, `d_lateral` across phone-horizontal) whose reachable set is a
2-plane: when the phone tilts, the lens genuinely swings FORWARD, and no `(dy, d_lateral)`
can express that. See "Rod tilt" below for what that cost in practice.

**Initial guess** from the mechanical prior: `offsetPhone` = `(-rodLength, 0, 0)` with the
operator's tape measurement as the rod length (it constrains `‖offsetPhone‖` directly, no
frame conversion), `yaw` = 0 (lenses aligned with phone), `pitch_residual` = 0. The search
box is deliberately anisotropic — tight along the rod where the tape pins it, ±13 cm across
it, which is both real clamp slop and a ~10° cone for the rod not being exactly along −x̂.
The solver (Nelder-Mead simplex on the 5-parameter cost) minimizes the distance between
mesh edges projected into the equirect at the candidate rig transform and Canny edges
detected in the equirect image.
With 3 calibration stills × hundreds of edge correspondences each, the system is highly
over-determined for 4 unknowns — convergence in milliseconds on-device.

**No server dependency**, works offline, instant feedback.

### Calibration UX: pre-scan, integrated into Dashboard card

The calibration step runs **before pressing Record**, reusing the existing reticle +
stillness gate + 360° trigger infrastructure:

1. **Trigger** — when a 360° camera is connected and no calibration exists (or the user taps
   **Re-calibrate** on the Dashboard card), the card transitions to **Calibration mode**.
2. **Capture** — the user walks to **3 distinct positions** (~1–2 m apart) in the room
   they're about to scan, pausing at each. The reticle confirms stillness, the 360° still
   fires, and the card shows progress: *"Calibration still 1/3 captured"*.
3. **Environment quality gate** — at each position, the app counts LiDAR mesh vertices
   within a 3 m radius. If below ~500 vertices, a warning surfaces before the solver runs:
   *"Move to an area with more visible surfaces for better calibration."*
4. **Solve** — after 3 stills, the solver runs (~1–2 s). The card shows the **reprojection
   residual** plus a **visual overlay** (mesh edges projected into one equirect still via
   the solved transform — green lines should align with actual room edges in the image).
5. **Accept / redo** — residual thresholds (RMS reprojection error in equirect pixels on
   the 512-wide working image): green (≤ 1.4 px), yellow (1.4–2.2 px), red (≥ 2.2 px,
   suggest re-adjust rig and re-calibrate). *Units fixed 2026-07-29 (review finding #3):
   the residual was mean-SQUARED px mislabeled "cm"; now √-converted to honest RMS px with
   behavior-preserving thresholds. True metric units would need per-edge range scaling —
   possible later, not needed for a relative quality gate.* The user accepts the calibration or taps
   Re-calibrate to redo.

**Trigger skew** between the phone and 360° camera is negligible for calibration: the
stillness gate ensures the rig is confirmed still when both captures happen, so the
phone pose barely changes during the ~1–3 s skew window. For production stills, the
existing `t_trigger + Δt_exposure` pose sampling handles the timing offset.

### Calibration persistence & reuse

The solved rig transform is **persisted in the rig profile** (stored in settings), tagged
with a timestamp and residual. At the start of each new scan, the Dashboard card shows the
last calibration's age and residual: *"Calibrated 2h ago (1.2 px residual)"* with a
**Re-calibrate** button.

- **No forced re-calibration** — the user is trusted to know when the rig has changed
  (phone re-mounted, rod adjusted, etc.) and taps Re-calibrate accordingly.
- **Telescoping rigs**: the reuse policy suggests validation at session start (the card
  shows a yellow prompt if the last calibration is from a different session and the rig
  type is marked telescoping).
- **Fixed rigs**: calibration persists across sessions; the card stays green.
- The calibration residual and the rig profile used for each scan both travel in
  `scan4d_metadata` so drift is visible downstream.

#### First-still drift spot-check

An automatic sanity check guards against accidental rig changes between scans. When the
**first 360° still** of a recording completes, the system:

1. **Reads the downloaded JPEG** from disk (the first still is always downloaded inline,
   even if bulk downloads are deferred to post-processing later).
2. **Evaluates the cost function** at the stored calibration parameters against the live
   capture's mesh edges + equirect edges — no re-optimization, just a single O(1) cost
   evaluation (milliseconds).
3. **Compares** the live residual to the stored calibration residual:
   - If `liveResidual > storedResidual × 1.4` AND `liveResidual > 1.7 px` (floor avoids
     noise on very tight calibrations; both √-converted from the pre-rename squared-space
     2.0× / 3.0), a **warning toast** appears:
     *"⚠️ Rig may have shifted — residual drifted from 1.2 → 2.4 px"*.
   - The warning is **non-blocking** — the scan continues (the user may have intentionally
     adjusted the rig).
4. The spot-check runs **once per recording session** (reset when recording starts).

**Design contract**: the first 360° still of each scan is always downloaded inline for
calibration validation, regardless of the bulk transfer strategy. This is a ~7s cost
(trigger + download) that would be paid anyway for the first capture — the spot-check
adds only the cost-function evaluation (milliseconds) on top.

### Per-still corrections

- **Timing** — trigger→exposure latency is nonzero and camera-specific; measure it in the
  calibration step and sample the ARKit pose at `t_trigger + Δt_exposure` (the stillness
  gate makes this forgiving — the pose barely moves during a valid capture).
- **Orientation source** — Theta cameras apply internal zenith (level) correction using
  their own IMU. **Keep zenith correction enabled** and calibrate position + yaw +
  pitch_residual (the 4 DOF model above). The pitch_residual absorbs any systematic bias
  in the camera's zenith correction without risking double-correction of roll/pitch.
- **Rod sway** — reject stills whose trigger window shows angular velocity above the
  stillness threshold; optionally cross-check the camera's own gyro metadata.


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

> **Status (2026-07-28): IMPLEMENTED v1** — `EquirectFaceExport` emits 5 faces per staged
> still (bottom dropped) into `images/` + Polycam `cameras/` JSONs (`is_keyframe`, exact
> 90° intrinsics `fx=fy=cx=cy=side/2`, additive `face`/`camera_pose_source`/`still_source`
> keys), sampled AFTER the privacy pass so faces inherit blur/consent. Poses use the
> mechanical-prior rig extrinsic (`AppConstants.rigRodHeightMeters` = 1.0 m,
> `rigYawOffsetDegrees` = 0). **Pending device validation:** face yaw sign + pano-center
> convention against the mesh (open the export in nerfstudio or eyeball face frusta vs
> room geometry); rig settings UI + solved calibration remain (calibration plan steps 2–3).
> The archived equirect stays in `equirect_stills/` alongside the faces.
>
> **Leveling gate (2026-07-28; Z1 promoted 2026-08-19):** face poses assume
> zenith-corrected (level) panos, so the exporter gates on the sidecar's camera model —
> Theta X and Theta Z1: validated (see the open-items list for the Z1's three-scan
> evidence); unknown models: NO pose-bearing faces (equirect archives; connect-time
> warning on the Dashboard card) until a gyro-metadata compensation feature lifts the
> gate. The `.assumedLevel` tier stays in the code for the next unvalidated model.

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

**Status (2026-07-24): IMPLEMENTED — blur path DEVICE-VALIDATED** (A12Z iPad, VR-mode
scan, 2 stills with persons: `360° privacy pass: 0 clean, 2 blurred, 0 excluded`, masks
visually confirmed on the exported equirects; the pass also survived a battery-idle pause
mid-export). Remaining spot-checks: the `clean` byte-identical path (tripod/remote still
with nobody in frame) and a seam/pole-straddling subject.

**⚠ REVISIT BEFORE MERGE — mandatory blur vs. informed consent (2026-07-24).** The current
implementation blurs 360° stills REGARDLESS of the privacy-filter toggle. That forecloses a
legitimate use case: a posed **group-photo 3D model**, where humans in frame are the point.
Agreed direction to implement before this branch merges:

1. **One toggle governs all capturing cameras** ✅ (2026-07-28; consent path
   device-validated same day: `360° stills staged UNBLURRED (1) — privacy filter was OFF`
   in the export log, `privacy_filter: false` confirmed in scan4d_metadata) — phone frames, proxy
   (glasses) frames, and 360° stills follow the same Privacy Filter switch:
   `stageEquirectStills` gates on the shared `privacyFilterWasOn` resolution (masks ⇒ ON,
   else the exported `privacy_filter` flag, fail-closed on garbage/unreadable metadata).
2. **Informed consent when OFF** ✅ (2026-07-28) — the switch is now `PrivacyFilterPill`:
   flipping it off expands an inline warning — *"People in view will be captured unblurred —
   moving people will corrupt texture maps."* — appending, when a 360° source is connected,
   *"The connected 360° camera captures ALL directions, including people behind you."*
   (An operator can point a phone away from bystanders; they cannot point a 360° camera
   away from anything.)
3. **Binary state per scan** — the toggle locks during recording (✅ implemented 2026-07-24:
   `.disabled(isRecording)`), so a scan is wholly filtered or wholly consented, never mixed.
4. **State travels with the data** — `privacy_filter` was already exported in
   scan4d_metadata; now documented in the schema (✅ 2026-07-24) so downstream pipelines can
   route/consent-check accordingly. The fail-CLOSED exclusion for *verification failures*
   stays even when the toggle is off? — no: with the toggle off there is nothing to verify;
   fail-closed applies only to the ON path, where a still that can't be verified must not
   ship. PRIVACY.md's 360° clause reworded accordingly ✅ (2026-07-28). `EquirectPrivacyBlur`
resamples each still into 6 pinhole cube faces (from a ≤4K working decode), runs Vision
person segmentation per face, projects the masks back into equirect space (longitude-
wrapping dilation covers the ±180° seam), and pixelates person regions on the
full-resolution equirect through CoreImage's lazy pipeline (~1%-of-width blocks). The
bottom (operator) face is blurred, not skipped — it only drops in cube-map exports.
`ScanExportManager.stageEquirectStills` stages `equirect_stills/` into Scan4D exports through
this pass, **regardless of the phone privacy-filter toggle** (a 360° still images people
the operator never saw), and **fail-CLOSED**: a still that cannot be verified is excluded
from the export (JPG + pose sidecar both). Device validation: export a scan containing
360° stills with a person in frame (expect `360° privacy pass: … blurred`, pixelated
person in the zip) and one with nobody (expect `clean`, byte-identical still).

### Blur ordering: equirect-first (decision, 2026-07-28)

The privacy pass pixelates person regions on the **full-resolution equirect first**
(`EquirectPrivacyBlur`), then cube-face export (`EquirectFaceExport`) re-samples the
already-blurred equirect into 5 pinhole faces. Because the gnomonic reprojection warps the
equirect grid, the uniform-color pixelation blocks (rectangles in equirect space) become
**warped quadrilaterals** on the cube faces — their shape distorts toward face edges where
the projection stretches, and stays roughly rectangular near face centers.

**Why equirect-first (chosen):**

- **1 Vision segmentation pass per still** (6 cube faces for detection, projected back
  into a single equirect mask) instead of 6 independent passes per still (one per exported
  face + one for the archived equirect). The ~6× processing saving matters on-device,
  especially for 61 MP Theta X stills where the per-still cost is already ~6 s.
- The warped blocks remain **easily recognizable** as artificial: large (~1/128 of equirect
  width ≈ 86 px on Theta X, 52 px on Z1), uniform-color regions that no natural texture
  produces. Their uniformity is a **downstream detection signal** — ingestion pipelines can
  identify these pixels as privacy-pixelated without requiring a matching depth mask,
  and discount them from texture/coloring before applying to model surfaces (e.g. for
  3DGS splat training, where privacy-blurred color would otherwise bleed into nearby
  splats).
- Privacy is equally effective: the blocks are identity-erasing at any viewing zoom
  regardless of their warped shape on cube faces.

**Discarded alternative — per-face post-cubemap blur:** generate 5 cube faces + 1 equirect
first, then run Vision person segmentation independently on each. Produces clean,
undistorted pixelation blocks per face and more accurate per-face masks (no
equirect→face mask reprojection error), but costs ~6× the segmentation time per still.
The downstream detectability advantage of the warped blocks and the processing cost make
equirect-first the better tradeoff for this branch. If a future camera or ingestion
pipeline makes per-face blur necessary, a new branch can revisit.

**Downstream contract:** the pixel artifact characteristics (uniform-color blocks, warped
shapes on faces, block size) are documented here; the actual detection/discounting logic
belongs in wisescan-ingestion, not in the iOS export.

## Phasing

| Phase | Deliverable | Gate |
| :--- | :--- | :--- |
| P0 | Voxel coverage grid (prerequisite, already on the roadmap) | coverage marking is depth-tested |
| P1 | `StillSource` seam refactor; onboard source behind it (no behavior change) | existing device tests still pass |
| P2 | Viability spike: Theta Z1 + Theta X via `theta-client`/OSC; identify & assess the third camera; measure trigger/transfer latency | written go/no-go per camera |
| P3 | Post-process 360° pipeline: BLE/OSC trigger, ticket matching, rig calibration flow, equirect export + privacy cube-face blur | calibration residual under threshold on a real rig |
| P4 | In-situ transfer + live coverage feedback; settings UI for source/rig profiles | scan cadence not degraded vs post-process |

## Known environmental instability (A12Z / pre-Apple7 GPUs)

RoomPlan's ObjectUnderstanding intermittently hits `EXC_BREAKPOINT` (`brk #0x1`, stack:
RoomPlan → `OUSession updateWithKeyframes:ouframe:`) on the A12Z iPad, typically at
save/teardown while its queue drains — observed repeatedly across branches (2026-07-24,
2026-07-28) with a clean app-side flow. Mechanism (from RoomPlan's own log): *"Gpu device
does not support RGBA16U/16f read_write and Apple7 family features. The fused frames will
have random values due to undefined behavior."* — Apple's OU keyframing runs with declared
UB on pre-Apple7 GPUs and occasionally asserts on the result. Not an app bug; RoomPlan
officially supports these LiDAR devices. Mitigation when it gets crashy during dev runs:
the Developer-Mode **Semantic Labeling** kill-switch disables the RoomPlan pipeline.

**Frequency escalation (2026-07-28): 2-for-2 on consecutive A12Z runs** at save-teardown
under the VR + RoomPlan + 360-stills workload — near-deterministic there, not rare. Data
is already crash-tolerant (the scan saves before the assert; DECISION-3 persists
CapturedRoomData as a sidecar, so post-relaunch Process can still build the room; a scan
whose sidecar didn't land surfaces through the bad-scan flow). Dev guidance: flip Semantic
Labeling OFF on pre-Apple7 iPads for 360-branch test sessions — none of the 360 features
under test need RoomPlan. **Product escalation lever (decision open):** if TestFlight
users on 2020-era iPads report save-time crashes, default `semanticLabeling` OFF when
`!MTLCreateSystemDefaultDevice().supportsFamily(.apple7)` — cost: no RoomPlan room, so no
plane registration on those devices (rescans fall back to relocalization-only seating).

## Performance Optimization Roadmap

> **Context (2026-07-29):** The export pipeline is the primary performance bottleneck — not
> the in-situ WiFi transfer during capture. A scan with 10+ equirect stills at 61MP spends
> significant time on privacy blur (6× Vision segmentation + mask compositing per still)
> and cube face generation (5× gnomonic reprojection + JPEG encode per still). The capture
> flow's ~6s per-still WiFi round-trip is tolerable; the export wall-clock is not.

### Step 1: Profile the export pipeline ✅ (2026-07-29)

`PerfDiag.timed()` markers added to all per-still export stages. Device profile (7 equirect
stills, Theta Z1 6720×3360, iPhone — `360run4.log`) produced this breakdown:

| Stage | Per-Call (ms) | Calls/Still | Subtotal | % of Still |
| :--- | :--- | :--- | :--- | :--- |
| `eq_decode` | 253 | 1 | 253 | 2.5% |
| **`eq_face_extract`** | **1,520** | **6** | **9,120** | **90.5%** |
| `eq_vision_segment` | 62 | 6 | 372 | 3.7% |
| `eq_mask_project` | 173 | 1 | 173 | 1.7% |
| `eq_pixelate` | 200 | 1 | 200 | 2.0% |
| **Privacy total** | | | **~10,100** | |
| `cf_decode` | 945 | 1 | 945 | 3.5% |
| **`cf_reproject`** | **5,190** | **5** | **25,950** | **96.4%** |
| **Cube face total** | | | **~26,900** | |

**Result:** CPU gnomonic reprojection (the pixel-by-pixel equirect→pinhole bilinear
sampler) is **94.5% of per-still cost** — the ONLY bottleneck. Vision segmentation
(~62 ms/face on the Neural Engine), mask projection, and CoreImage pixelation are all fast.

### Step 2: GPU-accelerate equirect→pinhole reprojection ✅ (2026-07-29)

**Approach: Metal compute shader** (chosen over CIKernel because the input is a raw bitmap,
not a CIImage in the privacy-blur decode path; Metal compute is consistent with the existing
`Shaders/` codebase and gives precise control over texture upload + readback).

- `Shaders/EquirectReproject.metal`: two kernel variants — `equirectToFace` (axis-aligned
  face bases for privacy blur) and `equirectToFaceRotated` (rotation-matrix faces for cube
  face export). Hardware bilinear sampling with repeat-address longitude wrapping.
- `EquirectGPU.swift`: Swift dispatch helper; shared `MTLDevice` + `MTLCommandQueue` for
  process lifetime. Creates GPU textures from bitmap data, dispatches the kernel, reads back
  `CGImage` (privacy) or JPEG `Data` (export). `isAvailable` guard for graceful CPU fallback.
- `EquirectPrivacyBlur`: uploads working bitmap to GPU texture once per still, dispatches
  all 6 face extractions via `EquirectGPU.extractFace`. Falls back to CPU `extractFace` if
  Metal unavailable. PerfDiag markers: `eq_face_extract_gpu` vs `_cpu`.
- `EquirectFaceExport`: same pattern for 5 export faces via `EquirectGPU.renderFace`.
  PerfDiag markers: `cf_reproject_gpu` vs `_cpu`.

**Device-validated (2026-07-29, `360run5.log`, 7 equirect stills, same device):**

| Metric | CPU (run4) | GPU (run5) | Speedup |
| :--- | :--- | :--- | :--- |
| `eq_face_extract` per face | 1,520 ms | **8 ms** | **190×** |
| Privacy pass (7 stills) | 71.0 s | **8.0 s** | **8.9×** |
| `cf_reproject` per face | 5,190 ms | **57 ms** | **91×** |
| Cube face export (7 stills) | 188.6 s | **8.9 s** | **21×** |
| **Total 360° export** | **259.6 s** | **16.9 s** | **15.4×** |

The reprojection bottleneck is eliminated. The remaining per-still cost is now dominated by
`cf_decode` (~930 ms, ImageIO bitmap decode for export faces), `eq_decode` (~250 ms),
`eq_vision_segment` (~65 ms × 6 = 390 ms), `eq_mask_project` (~170 ms), and `eq_pixelate`
(~185 ms). All of these are I/O-bound or Neural Engine-bound — further acceleration would
require reducing the decode resolution or batching Vision requests.

### Step 3: GPU-accelerate privacy pixelation (deferred — low impact)

Profiling shows `eq_pixelate` is only ~185 ms/still (now ~17% of the GPU-era per-still
privacy cost). The CoreImage lazy pipeline already handles the full-res composite
efficiently. This step is deferred — the new bottleneck is Vision segmentation + bitmap
decode, not pixelation.

### Transfer optimization: USB-PTP post-scan batch download

> **Status:** Future enhancement — deferred pending export performance work.

The WiFi AP transfer at ~4.5 MB/s is the capture-flow bottleneck (~2.5s per 11MB still).
Two complementary approaches for different user profiles:

**BLE trigger + post-scan USB-PTP batch download (power users):**
- During scan: BLE triggers only (sub-second, no WiFi captivity). Record `StillTicket`
  with sequence number + timestamp.
- After scan: connect the Theta via USB-C cable. Use iOS `ImageCaptureCore`
  (`ICDeviceBrowser` / `ICCameraDevice`) to enumerate and download files by path
  (e.g. `/DCIM/100RICOH/R0010001.JPG`), matched to StillTickets by filename sequence or
  EXIF timestamp.
- USB 2.0 transfer at ~40 MB/s → 10× 11MB stills in ~3s total vs ~25s over WiFi.
- Caveat: requires physical cable after each scan; requires `NSPhotoLibraryUsageDescription`
  entitlement.

**WiFi post-scan download (default / novice users):**
- Same BLE trigger + StillTicket flow, but download over WiFi AP after scan ends.
- No cable, slightly slower (~25s for 10 stills). Already described in the design doc's
  post-process transfer mode.

Both modes share the same StillTicket matching logic; the transport layer is the only
difference. Support both with a per-session or per-profile setting.

### Hybrid export: raw equirect + cube faces

Export both representations so downstream pipelines can choose:

- **Cube faces** (5× pinhole, current): immediate Polycam / basic pipeline compatibility.
  Every tool that expects pinhole cameras works unchanged.
- **Raw equirect** (archived in `equirect_stills/`): for Nerfstudio / 3DGS (gsplat)
  direct ingestion. Nerfstudio supports `EQUIRECTANGULAR` as a native camera model
  (`camera_type: 2`). 3DGS via gsplat also handles equirectangular.

**Deferred schema change:** Adding equirect frames as entries in `transforms.json` (with
`camera_model: "EQUIRECTANGULAR"` and the baked `cam_transform` as `transform_matrix`)
is deferred until the Nerfstudio end-to-end integration is tested. The raw equirects +
pose sidecars in `equirect_stills/` already carry all the information needed; the
`transforms.json` integration is a convenience for pipelines that read a single manifest.

## Security: the 360° camera link (threat model + planned controls)

**Threat model.** Theta cameras in AP mode broadcast the serial number in the SSID and
ship with the Wi-Fi password SET TO those serial digits; the OSC HTTP API has no
authentication in AP mode. Raw equirects capture bystanders in all directions and are
exactly the imagery our privacy pipeline exists to protect — but they sit on the
camera's storage (unencrypted, indefinitely), joinable by anyone nearby who can read an
SSID. Honest scope: Theta hardware has no per-client authorization, so "only this app
can download" is approximated by three controls, strongest first:

1. **Post-transfer auto-delete (P1, app-owned, fully in our control)** — after a
   verified download (scan stills at bulk-download completion; calibration stills after
   the solve-time batch), issue `camera.delete` for the transferred files so raw
   imagery never lingers on the weakly-secured device. Ordering matters: delete only
   AFTER verified transfer — the batch-download retry logic depends on camera-side
   persistence until then. A failed batch keeps files (retry works); a successful one
   leaves nothing to steal. Consider a "keep originals on camera" dev toggle for
   debugging only.
2. **Default-credential detection + rotation prompt (P2)** — if the connect flow holds
   the join password, warn when it equals the serial digits and point the user at the
   camera's password setting (X: on-camera touchscreen; Z1: RICOH app). Note factory
   reset reverts to the default, so the warning must persist, not be one-shot.
3. **Client-mode digest auth (P3, evaluate)** — in CL mode the OSC API supports digest
   authentication; if operationally viable on site Wi-Fi it closes the open-API hole
   properly, at the cost of network setup complexity.

Recon checklist for the above lives in the 2026-07-30 test plan (§9).

## Calibration solver: field findings 2026-07-30 (runs 6-10) + revised plan

**Rig reality (photos, 2026-07-30):** test rig = floor stand, Theta ~0.7-0.9 m above an
iPad tilted back ~30-45° in a clamp ~0.1-0.2 m off the rod axis. PRODUCT rig = handheld
telescoping grip, device size/angle, rod length, and Theta screw-mount rotation vary
per user AND per run. Consequences: **yaw is arbitrary by construction** (screw threads),
so mechanical yaw bounds are the wrong model; dy/dLat/pitch remain physically bounded
(rod range, clamp arm, zenith correction ⇒ pitch ≈ 0). The first-still spot-check is the
run-to-run drift guard, per design.

**What the runs established, in order:**
- run6: square-format downshift bug (2752×2752 → 512×512 working image) inflated all
  residuals; fixed (2:1-only). Three 0-edge stills sailed to a failed solve; fixed
  (edge-count hard gate). No stillness gate; fixed (settle-before-trigger).
- run8: unbounded solver scattered wildly on an unchanged rig (dy 0.87→4.38 m, yaw
  +17→−240°) at indistinguishable residuals ⇒ chamfer-proximity cost surface is
  near-flat in cluttered rooms. Physical bounds added.
- run9: diagnostics overlays (white=image edges, cyan=prior, red=solved) showed (a) the
  Sobel map SATURATED (ribbed ceiling = stripe field), (b) all mesh edges in one ~60°
  wedge — only the direction the iPad had meshed. Coverage hard gate added (90° yaw span)
  + card teaches a full-circle sweep; input bundles (jpg+pose+edges.bin) persist under
  Documents/rigcal_diag/inputs/ on perf-diag builds for OFFLINE solver work.
- run10: with 360° coverage and 104-155K edges, the solve STILL pinned to the same bound
  corner as run9 (dLat≈+0.3, yaw≈−30°, pitch≈−10°) — a consistent directional pull across
  runs/coverage regimes. Combined with the photos (pitch ≈ 0 physically, dLat ≈ 0.15),
  the pull is non-physical: prime suspect is the OPERATOR (the one scene element that
  moves WITH the rig ⇒ a systematic attractor), compounded by edge saturation.

**Revised plan (cost function is the critical path, iterated OFFLINE on the bundles):**
1. Operator exclusion — elevation band ✅ (2026-07-30): everything below −45° elevation
   is excluded from the solve AND spot-check, symmetrically (detect-time band mask +
   per-sample skip + fully-masked edges drop out of the mean; diagnostics draw the
   boundary in yellow and omit masked splats). Kills the rod/tripod (always below,
   rigidly attached — the most systematic attractor of all) and the handheld-rig
   operator; a stepped-back operator near the horizon still needs person-segmentation
   masking if repeatability stays poor. `calibrationElevationCutoffDeg` (−90 disables).
2. Discriminative matching: orientation-aware chamfer (projected mesh-edge direction
   must agree with the image edge orientation it matches) + strong-edge thinning /
   adaptive Sobel threshold targeting a fixed edge density (fixes saturated scenes).
3. Validate offline against photo-derived truth (dy≈0.8, dLat≈0.15, pitch≈0) with yaw
   FREE; only then widen the in-app yaw bound (screw-mount reality) and re-run on rig.
4. Keep: bounds on dy/dLat/pitch, coverage + edge-count + stillness gates, spot-check.

> **Flows & sequence diagrams for the implemented architecture:
> [REQUIREMENTS.md → REQ-033 Flows](../../REQUIREMENTS.md)** — overview + detailed diagrams for startup/start
> capture, AR/VR capture, stop/save, auto post-process, colorize, export/upload.

## PIVOT IMPLEMENTED (2026-07-30 EOD): post-process calibration

Landed as five commits — c7736f2 (capture side: sidecar-at-trigger, download queue,
sufficiency meter), 370af5c (auto-process on landing, manual-only coloring, equirect
download sweep step), ef1852e (EquirectPostCalibration: raw-frame solve against the
saved mesh, hybrid bounds, provenance stamping, rolling profile), a387969 (pre-scan
ritual → Developer-Mode diagnostics bench; session-yaw bridging deleted), 1435716
(sphere markers + 5-way preview cycle). Original proposal below for rationale.

User-proposed redesign, endorsed on the evidence — most of the day's fixes patched the
PRE-SCAN RITUAL (young mesh, sweep gates, stillness, format, sleep); this deletes the
ritual and keeps the solver (camera-frame cost, frozen masks, coverage metrics,
diagnostics all transfer 1:1, running at a better time with better inputs).

**Capture (during scan):** stillness-gated full-res equirect triggers only. Sidecar
records phone_transform + timestamp + trigger metrics + camera file URL + enumeration —
NO cam_transform yet. An off-main download queue tracks per-still state (not started /
downloading / done), yields to recording (shared Theta Wi-Fi), and may defer any or all
downloads to post-process under memory pressure. Live PiP/meter shows calibration
sufficiency (still count, distance spread, wedge coverage) — cheap, no solving.

**Process (automated post step):** finish pending downloads (camera-gone ⇒ card shows
"needs the 360° camera", queue persists; auto-delete from camera after verified download
per the security plan) → sample the best keyframe/equirect pairs by stillness, distance
spread, wedge coverage → run the calibration solve against the COMPLETE scan mesh with a
tight prior on persisted dy/dLat/pitch (proven repeatable across sessions) and yaw free
(proven per-session) → bake cam_transform + full pose data into every equirect sidecar →
persist refined geometry (rolling estimate, refined every scan). Insufficient equirects
or non-convergence ⇒ bake mechanical-prior/last-known poses, stamp provenance, warn —
never lose the scan. Drops: pre-scan calibration ritual (kept only as an optional
diagnostics bench), first-still spot-check + session-yaw bridging (self-calibrating
scans have nothing to drift from), Theta no-sleep outside recording (battery back).

**Process-button split (wanted regardless):** post processing becomes AUTOMATED on
landing at location detail; coloring returns to fully manual. Two states: isProcessed
(gates save/upload/rescan/link/color) + isColored. Progress via the per-scan phase pill
(reuse the export-progress machinery). Keep a manual "Redo Processing" in a menu
(unfinished downloads, solver errors, future pipeline upgrades). All jobs on the
background postprocess queue, FIFO, never blocking capture of the next adjacent space;
scan cards + location rollups surface in-flight state.

**Mesh preview markers (independent):** replace the 5-frustum equirect rendering with a
partially opaque sphere + small origin box + rim outline + forward arrow; preview cycle
becomes none / keyframes / equirects / motions / all.

## Session yaw: not a rig constant (2026-07-30 EOD)

Run 14 (two full calibration sessions, rig physically untouched between them): the
solved yaw jumped −44.7° → +58.3° while dy/dLat/pitch repeated (Δ ≤ 4 cm / 1.3°), and
the offline replica confirmed each session's solve found the true global basin OF ITS
OWN IMAGES — i.e. **the Theta re-derives its equirect yaw reference per session**
(its correction modes `ApplySemiAuto`/`ApplySave`/`ApplyLoad` exist precisely because
per-image correction parameters vary). Meanwhile run 13 vs run 14-A yaw repeated within
0.8° — the solver itself is precise; the reference under it moves.

**Architecture (implemented):** the model is split.
- **Calibration** persists the true rig constants — `offsetPhone` and `pitchResidual` —
  which repeat across sessions. The stored profile's yaw is only session-local.
- **Session yaw** is re-solved from each scan's FIRST still
  (`RigCalibrationSolver.solveSessionYaw`: 1-D global coarse scan + two fine passes,
  ~46 cost evals) inside the existing first-still spot-check, which is thereby promoted
  from drift detector to estimator. Scan stills bake `cam_transform` via
  `scanBakeProfile` (calibrated geometry + session yaw); still_0001 — which uploads
  before its own yaw exists — is re-baked after the solve.
- **Drift semantics sharpened:** with yaw absorbed per scan, an elevated spot-check
  residual now specifically means the rig GEOMETRY (clamp/rod) shifted.
- Uncalibrated (mechanical-prior) scans keep the static `rigYawOffsetDegrees` — the
  session-yaw solve currently requires a solved profile.

Remaining precision levers if per-still yaw noise (±28° observed) matters for face
poses: person-segmentation masking of the near-horizon operator, orientation-aware
edge matching.

## Code-review follow-ups resolved (2026-07-29)

The four open findings from the branch code review are closed:

- **#3 residual units** — solver now returns **RMS equirect pixels** (√ of the former
  mean-squared value that was mislabeled "cm"); thresholds √-converted so trip points are
  unchanged (green 1.4 / yellow 2.2 / drift floor 1.7 / drift multiplier 1.4). Sidecar
  field renamed `rig_calibration_residual_cm` → `rig_calibration_residual_px_rms`; the
  `RigProfile` Codable key change deliberately invalidates previously-persisted profiles
  (a stored squared value must not be reinterpreted as RMS) — recalibrate after update.
- **#8 double-download** — calibration stills are now fetched once (~11 MB saved per
  still); the `downloadLastCapture` stats/preview pass was redundant with the raw-bytes
  fetch. Superseded same day by **deferred batch downloads**: capture now stashes only
  pose + mesh edges + camera file URL, freeing the button as soon as the camera can take
  the next shot (~2–4 s per position instead of ~5–8 s); the downloads + edge detection +
  solve run as one progress-labeled batch when the last still is collected (retries per
  download — the shots persist on the camera, so a Wi-Fi hiccup never costs a walked
  position, but do NOT power the camera off between positions). Every stage logs a
  `[RigCal]` PerfDiag timing (mesh-edge extract, download, edge detect, solve) so the
  GPU-acceleration question is decided from device numbers: extraction is already
  overlapped under the in-camera stitch (wall-clock free unless it exceeds ~2 s) and the
  solver is one CPU step at the end — Accelerate `vvatan2f` batching (~5–10×) is the
  first lever if the numbers say it matters, a Metal cost kernel (VertexColorGPU pattern)
  the second. Additionally, calibration **downshifts the still format** to the camera's
  smallest JPEG for the session (X: 11K → 5.5K; the solver's 512-px edge map is ~10×
  oversampled either way), shrinking both the per-position stitch gate and the batch
  downloads; the scan format is restored at pipeline entry and on cancel, with a
  re-restore guard for instant-cancel races. The Capture tab also shows a **360° source
  chip** (model + serial + calibration state, sharing the wearable-PiP corner — the two
  sources are mutually exclusive) that turns orange persistently when the first-still
  spot-check flags drift, complementing the 5 s transient toast.
- **#9 export-time profile bypass** — `emitFaces` no longer applies a stored `RigProfile`:
  poses come exclusively from the sidecar's capture-baked `cam_transform` (stamped where
  the profile↔camera **serial binding is verified**); pre-contract sidecars without a baked
  pose fall back to the mechanical prior with a log line. Pose provenance
  (`camera_pose_source`) now derives from the sidecar's `rig_calibration_source`.
- **#10 silent capture failures** — calibration capture failures (no capture result,
  download failure, edge-detection failure) now surface on the calibration card via
  `captureErrorMessage` with actionable text, instead of log-and-return leaving the card
  stuck on "capturing".

## Status for next week (2026-08-01 stock-take)

Verified against the actual code (not just recalled) before writing this — two items
below turned out different from what earlier status notes implied.

### Solid — don't re-litigate
- Post-process calibration pivot is fully live: capture defers pose, batch download
  queue yields to recording, Process solves against the complete mesh, phase pill on
  scan cards is real (`bulkColoringMessages` reused for auto-postprocess, confirmed
  wired card-side, not just logged).
- Camera-frame lookup, anchor-frozen masks, global yaw solve, elevation-offset nuisance,
  and the **mirrored-longitude fix (v7)** are shipped and each individually confirmed
  against real captures via the scratchpad offline harness (numpy/PIL/cv2 + bench
  bundles) before landing.
- Measured-dy rig-height anchor (Settings, metric-persisted, m/in entry) works as a
  bootstrap; solve time is 5-6 s in Release (was 45-78 s Debug).
- Trigger-window motion probe + 3-cue rhythm (chime → click → done-tone) confirmed
  centimeter-scale motion in the field — the pose-compensation question is closed.
- Sphere/arrow preview markers with the full none → stills → equirectFaces → motion →
  all cycle are implemented exactly as specified (`KeyframeMarkerMode` in
  AppConstants.swift), not partial.
- Privacy guard now catches the pbxproj spelling of the file-sharing keys too (both
  vectors tested live-fire).

### Two corrections to earlier status
- **The pre-scan calibration ritual was never retired.** Dashboard's Calibrate/
  Re-calibrate buttons and CaptureView's full walk-3-positions overlay are still live
  code, running IN PARALLEL with the new automatic post-process calibration. This
  wasn't a leftover-cruft oversight so much as a decision that never got made — does the
  pre-scan flow still earn its place (e.g., as a bootstrap prior, or a diagnostics
  bench), or should it be removed now that Process calibrates every scan automatically?
  Needs a decision before it's either wired in deliberately or deleted.
- **Session-yaw bridging (the mid-recording spot-check/drift-toast UI) IS confirmed
  removed** — `spotCheckFirstStill`/`driftWarning`/`hasSpotChecked` no longer exist in
  RigCalibrationManager, and CaptureView has zero references. (`solveSessionYaw` the
  *solver function* is intentionally kept and reused for the <3-still yaw-only
  fallback path in EquirectPostCalibration — that one's correct, not dead code.)

### Major unproven questions — need device time next week
1. **Repeatability post-mirror-fix.** Only one v7 data point exists (360post6: dy=0.840,
   dLat=0.06, pitch=−3.5°, elev=+2.8°). Run 2-3 back-to-back scans, same rig untouched,
   and confirm dy/dLat/pitch/elev cluster the way dy/dLat/pitch did pre-mirror-fix
   (run13/14: yaw repeated to 0.8-1°). This is the highest-value test — it tells us
   whether the mirror bug explains the whole "systematic pull" story or whether a
   residual pull still needs offline cost work.
2. **Cube-face orientation ground truth.** Never actually confirmed since the mirror
   fix: export a scan, check the front face's content against the phone's heading at
   that pause, confirm left/right aren't swapped and nothing reads mirrored. This also
   validates the solver-vs-export convention unification (both use atan2(x,−z) now)
   downstream, not just in the solver's own diagnostic overlays.
3. **PnP path** — still "promising, unproven." SIFT found ~46 raw correspondences
   face↔keyframe; the homography acceptance test was the wrong model for a short
   baseline over a 3D scene. Next offline step (scratchpad `pnp_probe2.py` is the start):
   depth-backed `solvePnPRansac` using the keyframes' own LiDAR depth, run BEFORE more
   device time is spent on it.
4. **Does the "attractor" story fully close post-mirror-fix?** The elevation-offset
   nuisance and the operator-masking backlog were both diagnosed partly from PRE-mirror-
   fix data (mirrored geometry could itself have looked like an attractor). Re ‑derive
   whether operator masking is still needed once #1 above gives 2-3 clean repeatability
   runs — don't build it speculatively.
5. **Z1 leveling** — VALIDATED 2026-08-19 (fw 3.60.3) and promoted. Three healthy field
   scans: solved elevation offsets +1.4°/+2.8°/+1.4° (a leveling failure would land here
   and track rig tilt; it does not), pitch residual 0.09°/0.17° once the rod tape was
   corrected, anchor agreement ≤3.6°, residuals 3.7–4.4 px in the X's range, and the Z1's
   own IMU agreeing with ARKit to 1.6–2.3° mean. The glass-room scan was excluded — its
   failure was reflections defeating the edge cost (fixed by making the yaw anchor binding
   in v13), not leveling.
6. **Photometric (ZNCC) solver A/B — RUN 2026-08-19, photometric recommended for port.**
   Offline against all 23 field bundles (`tools/rigcal-ab/`): wins yaw decisively (glass
   room solves natively without the v13 clamp; the weak-geometry scan the edge cost
   triple-railed solves cleanly; per-still yaw spread works as a quality metric), needs
   ZERO elevation nuisance on 22/23 bundles including the old-era scans where the edge
   cost railed at ±11.25° (the offset was absorbing mesh/model error, not an image
   property), and confirms neither cost measures rod length — the tape-owned ±3 cm axis
   stays regardless (photometric's free-solve bias is LOW where the edge cost's was high,
   so the rod-rail direction semantics flip at port time). ~700 lines of edge/chamfer
   machinery and the mesh dependency retire when ported; needs an on-device validation
   cycle before deletion.
7. **Battery/thermal impact of `disableAutoSleep`** — never measured. Camera no longer
   naps between scans; a long field day's battery drain is unknown.
8. **Color-from-360°-faces dev switch** — built and committed, ZERO device runs. First
   test: toggle ON, recolor a people-free scan, compare against the OFF baseline.
8. **Downstream face+pose registration** — test plan item, never confirmed executed:
   drop exported faces/poses into the actual Polycam-format consumer and check they
   register against the mesh, not just that the sidecars look self-consistent.

### Remaining implementation work
- **Decide + act on the pre-scan ritual** (see correction above) — this is the biggest
  open architecture item, not just a test.
- **"Redo Processing" manual re-run** — designed (user question answered: keep it, in a
  menu, for camera-gone recovery / solver upgrades) but never built. No UI entry point
  exists today if someone needs to force a re-solve outside the version-bump mechanism.
- **Security P1 (post-transfer `camera.delete`)** — documented threat model and design
  only; zero implementation. Raw equirects still persist indefinitely on the Theta's
  unauthenticated storage. This is the one security item that's fully in our control and
  still open.
- **Security P2 (default-credential warning)** and **P3 (CL-mode digest auth)** — same,
  design-only, no code. P2 blocked on knowing whether the connect flow ever holds the
  join password (recon item from the original security test-plan section, never run).
- **`elevation_offset_deg` is a fitted absorber, not a measurement** — it IS consumed
  (`EquirectFaceExport` shifts both the face colour sampling and the face masks by it; an
  earlier note here claiming otherwise was wrong). Solved values across the 12 archived
  field bundles span −11.25° to +5.63°, which is too large to be a real registration
  constant and too inconsistent to be a rig property — it is soaking up error the rig
  model cannot express (see the phone-frame re-parameterisation item). Expect it to
  collapse toward zero once the offset lives in the phone frame; it stays for one solver
  cycle so that collapse can be observed rather than assumed. Note the shift is applied
  as a uniform latitude offset, which is not a rigid rotation of the sphere — another
  reason to treat it as temporary.
- **Rig-settings UI beyond the height field** — ticket-matching/BLE trigger, coverage
  marking, and other original P3 backlog items from earlier in the design doc remain
  untouched by the pivot.

### From the original plan — omitted in the first pass (2026-08-02 addendum)

The first stock-take covered the pivot arc but skipped the original design's roadmap.
Verified status per item:

**Communications — the largest omitted cluster, and the biggest remaining capture-
cadence lever (all unbuilt; ThetaCameraManager's own header says so):**
- **BLE trigger** (P3 line item: sub-second, no Wi-Fi captivity, phone keeps its
  network) — zero code. Today's trigger is OSC-over-Wi-Fi with a 2-4.5 s round-trip
  including stitch; BLE is the plan's answer to per-pause cadence.
- **`NEHotspotConfiguration` programmatic AP join** — zero code; the operator still
  joins the camera's Wi-Fi manually in iOS Settings.
- **USB-PTP post-scan batch download** (ImageCaptureCore, ~40 MB/s ≈ 10× the Wi-Fi AP)
  — designed in detail, explicitly deferred, zero code. Relevance went DOWN since the
  pivot (the yielding queue hides most Wi-Fi transfer inside the scan), but it's still
  the answer for many-still scans and camera-gone-at-Process recovery via cable.
- **In-situ vs post-process transfer as a per-session setting** — the pivot hard-wired
  an opportunistic middle path (queue drains between triggers, Process finishes the
  rest); no user-facing mode exists. Revisit only if a field need appears.
- **StillTicket matching** — DONE by other means: the sidecar-derived queue IS ticket
  matching (sidecar at trigger = the ticket; JPG matched later via camera_file_url).

**Rod-stillness "rig mode"** — unbuilt in full (lever-arm-scaled angular threshold,
sway settle detection, camera-IMU cross-check, honest reticle fill). Evidence note: the
trigger-window motion probe measured 0.7-6 cm with the cue rhythm followed, so the
current gate is adequate for a careful operator — rig mode is about making that robust
for everyone. The related per-still **sway REJECTION** ("Per-still corrections": reject
stills whose trigger window exceeds threshold, optionally cross-check camera gyro) is
also unbuilt — we measure and stamp `trigger_motion_m/deg` but never reject or retry.

**Exposure-time pose sampling** (`t_trigger + Δt_exposure`) — unbuilt, and closed BY
DATA for now: probe numbers say the tap pose is fine when the cue rhythm is followed.
Reopen only if field sidecars show routine >5 cm despite the done-tone.

**360° coverage marking** (mark all voxels within radius of the elevated camera with a
depth-tested occlusion check; the P0-gated item) — unbuilt; the sufficiency chip
(count · spread · pending) is the interim. The plan's open UX question stands: how the
overlay distinguishes "covered, transfer pending" from "confirmed".

**`StillSource` abstraction (P1)** — never landed as code; ThetaCameraManager is
concrete. The DATA layer is camera-agnostic (still_source in sidecars, equirect_stills
naming), but adding Insta360 or another camera still means refactor-first. The Insta360
SDK-access question (approval time, what the iOS SDK exposes) remains unanswered, so
P2's "written go/no-go per camera" is complete for Theta X (go) and Z1 (go —
leveling validated 2026-08-19; BLE control remains v1-auth-gated, so Z1 is OSC-only).

**Hybrid export** — SHIPPED (equirects + cube faces both export today). Deferred
remainder: equirect entries in `transforms.json` (`camera_model: EQUIRECTANGULAR`) for
Nerfstudio/3DGS direct ingestion — gated on an end-to-end downstream test, unchanged.

**Superseded by the pivot** (close these, don't carry them): pre-scan calibration
promotion/validation as the P3 gate (per-scan post-solve + parameter repeatability is
the metric now); GPU privacy pixelation stays deferred-low-impact as documented.

**Still-open design questions from the original plan** (cheap to answer, never
answered): cube-face FOV — 90° exact vs ~100° overlapping for seam feature-matching
(directly relevant to the weak PnP probe results); trigger→exposure latency variance —
calibrate-once vs per-still (the motion probe gives partial data already); where
dual-fisheye→equirect stitching runs for non-Theta cameras.

### Rig capture leaves LiDAR holes: ceiling + floor patches (field observation, 2026-08-02)

On the rig the iPad's pitch is clamp-fixed, so the scan translates but never pitches —
the ceiling (nearly all of it) and floor patches (especially near walls) never enter
the LiDAR frustum. Sorting the consequences honestly:

- **Fine downstream for the ceiling, with a texture caveat**: every still exports an
  `up` face with a good pose, so splat/NeRF pipelines reconstruct ceilings well;
  classic MVS struggles exactly where ceilings are blank/textureless.
- **The floor is the harder gap**: the bottom face is deliberately dropped (operator at
  nadir), so floor imagery is only oblique/grazing — weak for reconstruction AND absent
  from LiDAR. If floor completeness matters to the deliverable, this is the real hole.
- **Our own solver is quietly degraded**: missing ceiling mesh is part of why the
  diagnostic overlays show mesh edges confined to a thin band — the solver can't use the
  strongest vertical image structure (ceiling fixtures) as counterpart geometry, which
  softens elevation/dy constraints. More ceiling mesh sharpens solves for free.
- **Future coverage marking** would raycast against a holed mesh → false visibility.

**Mitigation available today (technique)**: a deliberate rig tilt at the first or last
pause — pitch the rod up a couple of seconds to paint the ceiling (optionally down at an
open floor patch). ~5 s per scan; improves the solver input and the mesh product at
once. **Later (build)**: detect the gap (mesh bbox top vs RoomPlan wall height) and
coach it ("ceiling not meshed — tilt the rig up briefly"); and the deferred
`transforms.json` EQUIRECTANGULAR entries let downstream use the full equirects
(including up face and partial nadir) rather than only the cut faces.

## Ready-for-main campaign: built + decided (2026-08-05)

The user's close-out list for merging this branch, worked as one campaign. Everything
below is committed and builds green; device validation of the connect cluster still
needs one run with automatic signing (first build must register the new
`com.apple.developer.networking.HotspotConfiguration` capability with the profile).

**Built this campaign:**
- **Connect UX cluster** (`06754fe`) — wearables-style one-button flow on the dashboard
  card (Add Camera… sheet storing SSID/passphrase → Connect → Disconnect), programmatic
  AP join via `NEHotspotConfiguration` (stored network applied on connect; join-then-
  probe), fluid path-monitor states (network lost → disconnected immediately; network
  back + stored → silent 2 s settle → probe), and a manual disconnect that removes the
  hotspot configuration and restores the camera's sleep delay.
- **Power-save kindness** (same commit) — `setSleepDelaySeconds` replaces the blanket
  no-sleep: keep-awake (65535 s) only while the capture tab is active; the AR-session
  idle teardown timer also returns the camera to its 180 s nap. A sleep/wake cycle
  re-derives the equirect yaw reference, which the per-scan solve now absorbs by design.
- **Rod-stillness "rig mode"** (`bb35184`) — when the Theta is connected at record
  start, `FrameCaptureSession.rigLeverArmMeters` (measured rig height, else the 1.0 m
  rod fallback) scales the angular stillness gate: ω ≤ v_still / L, floored at 0.3 m
  lever. Small phone rotations are magnified into camera translation by the rod; the
  translational gate is unchanged.
- **Ceiling/floor gap coach** (`13dd1fc`) — while recording with the Theta connected, a
  throttled off-main census of `ARMeshClassification` faces feeds ScanCoach: floor
  < 1500 faces late in the scan → WARNING "tilt the rig down briefly" (floor outranks —
  the nadir face is dropped downstream, LiDAR is the floor's only source); ceiling
  < 500 → guidance "tilt the rig up briefly". Both wait out 25 s of recording;
  phone-only scans never see them.
- **Redo Processing** (`f99a723`) — the designed manual re-run finally exists: on scans
  with 360° stills the Process button becomes a long-press menu with "Redo 360°
  Calibration", which strips the calibration provenance stamps and runs the normal
  engine (fresh solve against current Settings). Covers remeasured rig height /
  remounted camera / solver doubt — the cases the version-bump path can't.
- **Security P1** (`40b1d2a`) — post-transfer auto-delete per the security plan:
  disk-derived sweep (JPG verified on device + `camera_file_url` + no
  `camera_file_deleted` stamp) issues per-file `camera.delete`, stamps sidecars, runs
  from the live drain loop (files leave the camera seconds after transfer, mid-scan)
  and from the Process sweep for stragglers. Busy retries; already-gone stamps;
  unreachable aborts the pass. Developer Mode "Keep 360° Originals on Camera" toggle
  (default OFF, reset on dev-mode exit) for debugging.

**Residual decision (the "is the residual still useful?" question):** the solve
residual stays a DIAGNOSTIC, never a user-facing gate. It is logged per solve and
stamped into every sidecar (`rig_calibration_residual_px_rms`) — useful offline and for
downstream trust decisions — but absolute px thresholds went stale with every solver
change (square-format fix, elevation cut, camera-frame lookup, mirror fix) and the
value is scene-dependent (edge density, room size). Parameter REPEATABILITY across
scans (dy/dLat/pitch/elev) is the quality metric. Accordingly the capture-view 360°
chip no longer colors by profile residual; it reports state (rig prior ready / new
camera / none — all "solves at Process"). The green/yellow px constants survive only
inside the pre-scan calibration ritual (Dashboard Calibrate + overlay), which the pivot
already designates an optional diagnostics bench — recommended follow-up: retire it to
a dev-gated bench in its own pass, not in this campaign.

**Deliberately deferred (user-confirmed, downstream tests first):** USB-PTP batch
download; `StillSource` abstraction (stored data is already camera-agnostic);
360° coverage marking — user is weighing a cheaper alternative, a live AR marker at
each still's estimated capture position (~one entity per still, trivial cost);
cube-face FOV 90° vs ~100° overlap; `transforms.json` EQUIRECTANGULAR entries.

**Connect cluster device-validated (2026-08-05, 360post10):** join → probe →
`Connected: RICOH THETA X` twice in one session, manual disconnect restored the
camera's auto-sleep and released the Wi-Fi, re-join 8 s later, keep-awake armed on
entering capture. Known cosmetic: **iOS pops "Unable to join" for the camera's
internet-less AP even when the association is up** — the system's captive-portal probe
finds no internet and calls that failure; our probe is authoritative and the card
status reflects it (footer text + code comment document this). The Add Camera sheet
now prefills the factory password (serial digits parsed from the SSID, suffix-agnostic
— real-world SSIDs vary: `.OSC`/`.ASC`) whenever the password field is empty or still
holds our own prefill.

**Connect UX — future design notes (user brainstorm, deliberately not built):**
- A dropdown of NEARBY camera SSIDs is not buildable with standard entitlements —
  Wi-Fi scanning needs `NEHotspotHelper`, a special entitlement Apple grants by
  written approval. `NEHotspotConfiguration(ssidPrefix: "THETA")` exists but can't
  blind-join: the passphrase is per-camera (serial digits), so a prefix join only
  helps a shared-passphrase fleet.
- A dropdown of STORED cameras = multi-camera profiles (today we store exactly one
  SSID/passphrase). Natural home for the idea once >1 camera per operator matters;
  the sheet + card flow was built to absorb it.
- Automated password rotation (extends security P2): the app could set a strong
  password on the camera after first connect. Needs an edge-case plan before
  building — rotation silently invalidates every OTHER paired device's stored
  password (rotation ownership? propagation? manual fallback?), and a factory reset
  reverts to the serial-digits default behind our back (the P2 warning must stay
  persistent, not one-shot).

**BLE trigger — next focused session:** camera-specific GATT pairing (Theta's BLE API
needs its own auth/pairing flow), sub-second trigger without Wi-Fi captivity. Scoped
out of this campaign as the one item needing dedicated protocol work; the connect
cluster's UX (stored camera identity on the dashboard card) is built to absorb it.

**DECIDED 2026-08-05: the BLE-first bootstrap below is the IDEAL connect flow** —
BLE scan → read model/serial over GATT → wake the camera's AP (Network Type = Direct)
→ derive SSID + factory password → `NEHotspotConfiguration` join → probe — with Wi-Fi
staying the bulk-transfer plane and BLE Take Picture as the trigger. Pursued right
after **one more device round on the campaign build**, which gates it:

1. Rig scan long enough to leave real gaps → floor/ceiling coach prompts fire.
   Field round 1 (360post11): ceiling prompt fired and earned its sweep; floor stayed
   quiet because the floor MESH was genuinely there (oblique LiDAR paints floor counts
   fast — the gray floor in keyframe coloring was an IMAGE-coverage gap, which the
   mesh census can't and shouldn't see). Verdict: prompts are useful with or without
   360 capture → now enabled for ALL scans with source-appropriate wording ("tilt the
   rig" vs "sweep"), and every census refresh logs `[Coach] census: floor= ceiling=
   wall= total=` so the thresholds (floor 1500 / ceiling 500) get tuned from real
   numbers next round.
2. After stills transfer mid-scan, confirm the originals are GONE from camera storage
   (sidecars gain `camera_file_deleted`); flip "Keep 360° Originals on Camera" for a
   control run if needed.
3. Long-press Process → "Redo 360° Calibration" re-solves and the sphere markers stay
   put (stamps stripped + rewritten).
4. Add Camera sheet: factory password prefills while typing the SSID; a hand-typed
   password survives SSID edits.
5. Power kindness cycle: keep-awake on entering capture, camera back to 180 s nap on
   idle teardown and on manual disconnect.
6. Rig-mode stillness: the lever-scaled angular gate still fills the chip at a
   comfortable pause cadence on the real rod.

Round 2 additions (post-360post12 thermal crash + field feedback): **thermal coach**
("🌡️ Device hot — wrap up and save" at `.serious`, critical wording at `.critical` —
on the field iPad, serious preceded the RoomPlan/OU crash by ~30 s, enough to save);
**near-depth obstruction warning** ("🔧 Something is right in front of the camera…",
rig/handheld wording) from a throttled LiDAR census — returns under 0.2 m sustained
4 s = rig knob/strap/finger corrupting depth (field case: tension knob glancing the
side view all day); and **fastMotion demoted to guidance** — as a warning it fired
through every normal walk phase (warnings are exempt from cooldown/dismiss by design)
and trained the operator to ignore the channel; it now needs 3 s sustained motion,
shows ≤3×/session with 30 s cooldown, and the warning channel stays credible for the
rare act-now moments (thermal, obstruction, capacity). Verify on the next run: knob
warning fires with a finger held near the lens ~5 s; fastMotion appears at most
briefly; thermal line appears if the device ramps again.

**BLE bootstrap findings (verified against ricohapi/theta-api-specs
theta-bluetooth-api):** BLE can seed the whole Wi-Fi flow with no extra entitlement —
CoreBluetooth needs only an Info.plist usage string, unlike NEHotspotHelper.
- **THETA X: no Wi-Fi dependency at all.** The spec's getting-started opens with
  "RICOH THETA V and Z1 require following steps… RICOH THETA X does not require these
  steps" — on X, Bluetooth is enabled on the camera's touchscreen and the app connects
  directly, no UUID registration.
- **V/Z1: Wi-Fi first, but only ONCE.** Register the app's UUID over OSC
  (`camera._setBluetoothDevice`, plus `_bluetoothPower: ON`), which returns the BLE
  deviceName (= serial); thereafter BLE authenticates standalone by writing the UUID to
  the Auth characteristic (service 0F291746-0C80-4726-87A7-3C501FD3B4B6, char
  EBAFB2F0-0E0F-40A2-A84F-E2F098DC13C3). Natural hook: register during the first
  Add Camera Wi-Fi session, which we already own.
- **Identity over GATT (V/Z1/X, read-only Camera Information service):** Model Number,
  Serial Number, Firmware, WLAN MAC, BT MAC. Serial digits = factory password; model +
  serial = SSID candidates. Caveat: `NEHotspotConfiguration` needs the EXACT SSID
  string and the 2-letter model code + suffix vary in the field (.OSC vs the observed
  .ASC) — try candidate SSIDs (a failed apply is cheap) or confirm once with the user.
- **WLAN Network Type is writable over BLE (V/Z1/X):** 0 = OFF, 1 = Direct (the
  camera's own AP), 2 = Client — the app can wake the camera's AP without anyone
  touching it. Dream bootstrap: BLE scan → read model/serial → write Direct mode →
  join derived SSID → probe.
- **Read WLAN Password State (Z1 ≥3.50.2, X ≥2.80.1; ours is 2.92.0):** BLE-side
  default-credential detection — feeds security P2's warning directly.
- **Take Picture characteristic (V/Z1/X):** the sub-second trigger itself; Camera
  Control Command v2 Get Info/State/Options on Z1 ≥3.10.2 / X ≥2.20.1.
BLE-session probe order: CoreBluetooth scan on the X (what name it advertises) →
read Camera Information → Take Picture → wake AP via Network Type → then wire the
full bootstrap into Add Camera. **Probe bench BUILT (2026-08-05): Developer Mode
surfaces a "360° BLE Probe" card on the dashboard (ThetaBLEProbe.swift) — Scan lists
every named peripheral with RSSI (learns the X's advertised name), tapping one
connects and logs a FULL service/characteristic discovery, Camera Information
model/serial/firmware are read automatically (auth errors here = pairing needed —
also probe data), and Take Picture / Wake AP buttons drive the two write probes.
All findings land in the on-card log + unified log (category `bleprobe`). Camera-side
prerequisite: Bluetooth ON in the X's touchscreen menu.**

**BLE field rounds 1–2 (360ble1 / 360ble1-R2, 2026-08-05 evening):**
- **Probe #1 ANSWERED:** the X advertises its bare 8-digit serial ("14100112",
  advertised name) — same convention as V/Z1. Production scan filter = 8-digit-name
  match / exact stored serial.
- **Probe #2 ANSWERED:** full GATT enumerates while UNAUTHENTICATED — 10 services
  including Bluetooth Control (0F291746, auth char EBAFB2F0 write-only), Camera
  Information (9A5ED1C5), WLAN Control (F37F568F, Network Type 9111CDD0 R/W/N), and
  Camera Control Command v2 (B6AC7A7E). **The v1 Shooting Control service (1D0F3602)
  is ABSENT on X 2.92.0** — Take Picture must ride the v2 command channel (or appear
  post-auth; round 3 tells).
- **Probe #3 ANSWERED (negatively):** every functional read/write — Camera Info reads,
  Network Type read AND write — returns "The handle is invalid" until authenticated.
  The spec's "X does not require these steps" evidently means only the Wi-Fi-side
  UUID registration; the AUTH WRITE still gates everything. Wake AP therefore never
  fired (and the Wi-Fi side's repeated /osc/info timeouts that evening were the
  camera's AP napping — exactly the case BLE wake exists for).
- **Round-3 build (ready):** on connect the probe now auto-writes a self-generated
  persisted UUID (UTF-8 string, no camera._setBluetoothDevice registration) to the
  auth char, then re-discovers and re-reads — including Camera Control Command v2
  **Get Info (A0452E2D)**, which returns model/serial/firmware/MACs/uptime as ONE
  JSON read (the X-native identity path, X ≥2.20.1). Bench also hardened: likely-
  Theta rows float to top tagged in cyan, whole row tappable (round 1's dead taps =
  Spacer gap not hit-testable), and a 10 s connect watchdog logs when
  CBCentralManager.connect pends silently (it never times out on its own).
- **Round 3 (360ble3) — DECISIVE:** the X REJECTED the self-generated auth UUID
  (same handle-invalid), and `camera._setBluetoothDevice` is documented Z1/V-only ⇒
  **the entire v1 GATT family is vestigial on X 2.92.0 — stop probing it.** And the
  breakthrough: **Camera Control Command v2 Get Info returned the full identity JSON
  unauthenticated** — `{"model":"RICOH THETA X","serialNumber":"14100112",
  "firmwareVersion":"2.92.0","_wlanMacAddress":…,"uptime":…}` in ONE read. The
  identity half of the bootstrap is solved.
- **The X-native v2 map (from ricohapi/theta-ble-client source — used as REFERENCE,
  deliberately not adopted as a dependency: our surface is five characteristics and
  the KMP pod would drag a Kotlin runtime + CocoaPods into an SPM project):**
  CCv2 service B6AC7A7E — GetInfo A0452E2D, GetState 083D92B0 (battery,
  _captureStatus, _latestFileUrl!), GetState2 8881CE4E, NotifyState D32CE140,
  GetOptions 7CFFAAE3, SetOptions F0BCD2F9, **REQUEST_SHUTTER_COMMAND 6E2DEEBE**
  (UTF-8 `{"name":"camera.takePicture"}`); WLAN v2 — **WRITE_SET_NETWORK_TYPE
  4B181146** (`{"type":"AP"}` = wake the camera's own AP), scanned-SSID/connected-
  info notifies; CAMERA_POWER B58CE84C (R/W/N — wake-from-sleep candidate). Every
  one of these appeared in the field discovery.
- **Round 4 field note: the v2 CONTROL surface is gated by standard BLE bonding.**
  First protected operation triggers the iOS pairing dialog asking for a code — the
  6-digit passkey displays on the X's own screen (LE passkey-entry; open the camera's
  Bluetooth screen if it isn't visible). One-time: iOS and the camera both persist
  the bond; subsequent connections need no code. THIS is what replaced the vestigial
  v1 auth char on X — identity (GetInfo) reads openly, control requires a
  user-confirmed bond, i.e. proof of physical possession of the camera. That's a
  better security posture than V/Z1's UUID scheme and slots straight into the
  production Add Camera flow as its one-time pairing step (and complements the P2
  default-credential story: the Wi-Fi password can be weak-by-default, but BLE
  control was never open).
- **Round 4 RESULTS (360ble4) — the BLE trigger is PROVEN.** Two `camera.takePicture`
  shutter writes accepted across two sessions, each answered by
  `NotifyState(v2) = {"_latestFileUrl":"http://192.168.1.1/files/100RICOH/R00102xx.JPG"}`
  — the camera pushes the NEW FILE URL over BLE the moment capture completes. That's
  strictly better than the OSC path's poll: the production still pipeline can take
  its StillTicket (camera_file_url) from the BLE notify with no HTTP round-trip at
  all. GetState works bonded (battery, _captureStatus, temps, _latestFileUrl;
  camera reports ELECTRONIC_COMPASS_CALIBRATION advisory), GetState2/WifiInfo read
  clean, notify stream ticks live (board temps). Bonding held across reconnects —
  no further codes. CAMERA_POWER (B58CE84C) is handle-invalid = vestigial like the
  rest of v1; X wake-from-sleep would go via SetOptions `_cameraPower` if ever
  needed. `SetNetworkType {"type":"AP"}` was ACCEPTED twice; whether the AP actually
  rose is the one unverified link — next micro-test: Wake AP → tap Connect on the
  Theta card → if it joins and probes, the ideal flow is proven END TO END.
- **Round 5 field reframe (manual-wake test): the nap is POWER, not network.** With
  the camera manually woken, the AP advertised AND the BLE shutter fired — then after
  joining Wi-Fi, BOTH shutter channels worked simultaneously. So BLE and the AP
  coexist fine; the napping state is the camera ASLEEP (Wi-Fi radio off, BLE alive,
  networkType still "AP" — the accepted `{"type":"AP"}` write was a no-op, and its
  payload is verified verbatim against the SDK). New probes (2976511): **Wake
  Camera** = SetOptions `{"cameraPower":"on"}` (the real wake knob); **NetOpts** =
  GetOptions readback of `_cameraPower`/`_networkType`/**`_ssid`/`_password`** — if
  the bonded link serves the camera's own credentials, the production bootstrap
  reads its exact join credentials over BLE and both the serial-derived password
  and the .OSC/.ASC SSID guessing disappear; Wake+Drop BLE retained as fallback
  test; WlanPasswordState (E522112A) added to auto-reads (security P2 indicator).
  Test order when camera naps: Wake Camera → watch for SSID → Connect. Then NetOpts
  regardless (credential readback matters even when awake).
- **ROUND 6 FIELD: THE IDEAL FLOW IS PROVEN END TO END.** Wake Camera
  (`SetOptions {"cameraPower":"on"}`) woke the SLEEPING camera over BLE, the AP
  rose, and Connect succeeded — scan → identity → wake → patient join → connected,
  zero camera touches. The BLE probe program's core mission is complete; what
  remains is an optimization: the combined five-name GetOptions request came back
  as a single error byte (0x82 = request refused; spec shows the response should be
  a JSON object and lists `_defaultWifiPassword` as legal), so the probe now SPLITS
  the readback — `_networkType`/`_cameraPower` first, then the credential names —
  to isolate whether the X serves `_ssid`/`_password` over the bond at all.
- **ROUND 7 (360ble7): PROBE PROGRAM COMPLETE — final verdicts.**
  (1) **State readback WORKS**: `GetOptions → {"_cameraPower":"on","_networkType":
  "AP"}`, delivered via the GetOptions NOTIFY (X-only per spec) — the clean JSON
  arrived before our own write-ack. Production can verify wake state over BLE.
  (2) **Credential readback REFUSED**: the `_ssid`/`_password` request produced no
  response; subsequent direct reads returned the PREVIOUS response with its opening
  `{` clobbered to 0x82 — which also retroactively explains round 6's lone 0x82
  (stale-buffer read artifact). Verdict: the X withholds Wi-Fi credentials over
  BLE — security-consistent (bond grants control, not secrets) — so the bootstrap
  keeps stored SSID + serial-derived factory password.
  (3) **Protocol note for production: treat the NOTIFY as the GetOptions response
  channel; direct reads of request/response chars are unreliable** (0x82-clobbered
  stale buffers, seen on GetState once too).
- **GRADUATION SHIPPED (25e82ed): production ThetaBLEManager.** Encodes every
  field rule (v2-only, GetInfo identity, cameraPower wake, shutter with NotifyState
  file-URL push seeded from GetState, notify-as-response-channel, per-slot
  watchdogs). Add Camera → "Find Camera via Bluetooth": scan (8-digit serial ad) →
  connect → identity → one-time passkey bond (forced by the wake write, code on the
  camera screen) → derived SSID + factory password saved → patient Wi-Fi connect;
  unknown models fall back to prefilled manual entry. Connect is BLE-first (wake
  then join, no-op without pairing). Scan captures ride the BLE shutter when the
  link is ready — OSC fallback ONLY on a failed write (confirmation timeout
  surfaces rather than double-triggering). Sheet gains "Forget This Camera"
  (credentials + pairing state; iOS bond removal is in Settings → Bluetooth).
  **TRUE-TEST SCRIPT (from-zero):** forget camera in sheet + forget the bond in iOS
  Settings → Bluetooth + camera Bluetooth ON → Add Camera… → Find Camera via
  Bluetooth → enter passkey from camera screen when iOS asks → expect: sheet
  dismisses, card connects on its own (BLE wake → join → probe), "Bluetooth link
  active" caption appears → record a scan: stills should log "Shutter via BLE —
  file pushed" with sidecars carrying the pushed camera_file_url; downloads +
  camera.delete sweep unchanged over Wi-Fi.
- **RE-PAIRING: the iOS system bond is the one that matters (field, 2026-08-18).**
  After an ATT 0x03 refusal the recovery went: cleared the pairing on the camera →
  still refused; app-level Forget This Camera → still refused. What finally released
  it was **iOS Settings → Bluetooth → ⓘ → Forget This Device**. The app's own
  "Forget This Camera" clears credentials and our stored peripheral identifier, but
  it CANNOT remove the iOS bond — no public CoreBluetooth API does — so on its own it
  never fixes a bond-state problem. Between the camera-side clear and the iOS-side
  clear there is also an intermediate state where the link reaches `.ready` (the open
  CCv2 subset enumerates unencrypted) and then dies ~29 s later on the NotifyState
  CCCD write, which is the ATT transaction timeout; `noteUnproductiveLink` detects
  that pattern and prints the recovery order. Recovery order, decisive step first:
  1. iOS Settings → Bluetooth → ⓘ → **Forget This Device**
  2. clear the pairing on the camera's own screen
  3. Forget This Camera in the sheet, then Add Camera → Find Camera via Bluetooth
- **First-tap connect failure SOLVED (360ble5 → 8d2fe19):** the field pattern "first
  Connect always fails, second always succeeds" was DHCP lag, not SSID lead time —
  `NEHotspotConfiguration.apply` completes at ASSOCIATION, the camera's DHCP/route
  takes several more seconds, and the old single 1.5 s-settle probe landed in the
  gap (the second tap inherited the ready link via alreadyAssociated). Connect now
  retries the probe every 2 s for up to ~12 s, only for the can't-reach class;
  firmware-gate/leveling refusals still fail immediately. **Validated (360ble6):**
  one tap → probe 1 misses the gap → one 2 s retry → Connected. Single-tap connect
  confirmed; the DHCP settle on this X is ~2-4 s.
- **Round 4 (built, 34f8b5b):** probe rewired to the v2 paths — auto-reads
  GetInfo/GetState/GetState2/Wi-Fi info + notify streams on connect; Take Picture =
  v2 shutter command; Wake AP = v2 network type `{"type":"AP"}`. v1 auto-reads and
  the auth write removed. Expected log on success: `GetState(v2) = {...batteryLevel
  ...}`, `✅ write Shutter(v2) accepted` + camera click, `✅ write SetNetworkType(v2)
  accepted` + the AP appearing (then the Wi-Fi card's Connect completes the whole
  ideal flow by hand).**

## BLE graduation: from-zero TRUE TEST PASSED + first yaw-alias bite (2026-08-06, 360ble8)

**True test end to end from zero:** pair (passkey) → BLE wake → auto-join
THETAYR14100112.OSC → one settling retry → Connected — then SIX scan stills all
"Shutter via BLE — file pushed", tap→file-listed 3.3-3.6 s (OSC field baseline was
4.4-5.0 s: **~1.2-1.5 s faster per still**), keep-awake cycled correctly.

**First field yaw-alias:** the scan's face coloring came out 180° off around Y. The
camera's session yaw reference genuinely reset (power cycling during the from-zero
test — the exact run14 behavior the per-scan solve exists to absorb), the solve ran
and converged (yaw=-151.5°, 8.69 px, 5 inputs, 8 s Release) — but onto the 180°
ALIAS lobe (rooms alias ~90/180°; the residual was competitive, so scene symmetry
won). This risk was documented from run13 ("still1 preferred a +50° alias") and this
is its first bite. Fix direction (solver v8): photometric lobe disambiguation —
score the top global-scan lobes by image-content correlation against one or two
PHONE KEYFRAMES (rigidly co-mounted, so the right lobe's rendered view matches the
keyframe; the wrong lobe shows the opposite wall). Prototype OFFLINE first against
this run's rigcal_diag bundle per the established workflow. Note also: this run's
log shows the persisted profile rejected by the mechanical gate while the fresh
solve accepted a LARGER pitch — the two bounds checks disagree; audit when touching
the solver.

**Wi-Fi → BLE migration assessment (what else can ride BLE for speed):**
- **Battery → BLE (BUILD-WORTHY):** GetState carries batteryLevel/_batteryState and
  NotifyState PUSHES battery changes — replaces the HTTP battery fetches and gives
  the card live battery even mid-transfer or pre-join.
- **Keep-awake (sleepDelay) → BLE SetOptions (CANDIDATE):** option-key over BLE
  unverified; value is marginal (keep-awake matters during capture, when Wi-Fi is
  joined anyway) — verify opportunistically, don't chase.
- **Stays on Wi-Fi, correctly:** /osc/info probe (it IS the Wi-Fi-link validation),
  leveling gate + still-format options (rare, always in joined contexts), JPEG
  downloads (bulk bytes; BLE would take ~minutes/still), camera.delete sweep (no
  BLE file API exists).
- **Already migrated:** shutter (this build) — the largest per-still win available.

## Solver v8 prototype: photometric lobe disambiguation VALIDATED offline (2026-08-06)

Numpy prototype (scratchpad `lobe_check.py`) against the rigcal_diag inputs (3
cal-era stills + phone poses + mesh edge segments — solver-input data only, nothing
extra): **cross-still color consistency** — sample each edge-segment midpoint's gray
value in every still pair through the candidate rig geometry and score the mean
absolute difference (near points < 6 m). Result: one clean minimum at yaw ≈ 357°,
**the 180° alias scores 1.95× worse**, top-5 minima all within ±6° of the winner.
The mechanism: a global yaw flip re-aims every camera 180° about its OWN position,
so two stills at different positions sample different physical surfaces — colors
decorrelate; only the true yaw keeps them sampling the same points.

**v8 design (port after validating on the failing scan):** post-solve, evaluate
consistency(yaw*) vs consistency(yaw*+180°) on the already-loaded working images +
edge segments (two evaluations, milliseconds); if the alias wins by margin, re-run
the local refine from the flipped lobe and stamp `yaw_lobe_flipped` provenance; if
neither wins by ≥~1.15×, keep the geometric answer and log the ambiguity. Also fix
while in there: the profile mechanical gate rejected pitch 2.2° while the solve
envelope accepted −3.83° — reconcile the two bounds checks.

**Validation gap:** the bundle's inputs/ folder held only the cal-era 3-still set —
post-process solves save overlays, not inputs. Final validation needs the FAILING
scan itself (equirect_stills + sidecars + mesh.obj): AirDrop the scan folder via the
Files-app build, or a .scan4d export (contains all of it plus keyframes).

**Theta Z1 (user wants a comparative run — better low-light optics, 6720×3360
equirects):** Wi-Fi path is essentially ready (minFirmwareZ1 gate, THETAYL SSID map,
leveling + 2:1 solver + face cut are resolution-agnostic). BLE differs by design:
Z1 = Wi-Fi UUID registration (`camera._setBluetoothDevice` + `_bluetoothPower ON`)
→ BLE auth write → v1 characteristics (Shooting Control 1D0F3602 exists there; CCv2
requires ≥3.10.2). Probe bench extended (518d2d4): "Register (Wi-Fi, Z1)" + "Auth
(BLE, Z1)" buttons, model-adaptive Take Picture / Wake AP (v2 when present, else v1
write-0x01), v1 identity reads in the discovery sweep. Z1 probe protocol: connect
its Wi-Fi manually (THETAYL<serial>.OSC / serial digits) → Register → Scan+tap in
the BLE probe → Auth → standard buttons. Production ThetaBLEManager stays X-only
until the Z1 probe run writes the facts.

## v8 FINAL DESIGN: keyframe-anchored yaw (failing-scan validation, 2026-08-06 PM)

The staging bundle of the alias scan overturned two assumptions and settled the
design. Chain of evidence (scratchpad: lobe_check_scan.py, point_sanity.py,
keyframe_anchor.py, frame_check.py):

1. **Frame conventions proven:** the numpy replica reproduces the sidecar's baked
   `cam_transform` at the solved yaw to 1e-4 (rotation and translation) — every
   offline number below is in the solver's exact frame.
2. **The error was 136°, not 180°:** keyframe-anchored scoring (project each
   keyframe's depth-validated 3D points into the nearest still's equirect through
   candidate geometry; compare grays against the keyframe pixels — phone imagery
   carries ABSOLUTE orientation) finds the true yaw at **+72°** (top-5 all within
   69–81°). v7 solved −151.5°. The user's "180° off" was an eyeball approximation.
   A flip-only post-check would NOT have fixed this scan (score at +28.5° = 0.304
   vs 0.267 at +72° vs 0.326 at solved) — good thing it was validated first.
3. **Still↔still consistency is NOT a safe disambiguator:** it picked −72° — wrong
   sign. With stills laid out along a dominant walk axis, still↔still photometric
   consistency is quasi-invariant under yaw REFLECTION about that axis; keyframe
   anchoring breaks the symmetry because keyframe orientations are absolute.
   (The cal-era 1.95× result measured lobe contrast, not ground truth.)
4. **Depth-unprojection validated** independently: cross-keyframe |Δgray| 0.10–0.15
   vs 0.24–0.32 shuffled baseline.

**v8 design (to implement):** keyframe-anchored yaw SEEDING in
EquirectPostCalibration — load up to ~8 spread keyframes (images/ + depth/ +
cameras/ live in raw_data already; the colorizer's depth reader knows the PNG
format), unproject at stride, decode stills to small grays, scan the yaw circle
(3° steps) with the keyframe-anchored score, then constrain the existing edge-cost
solve's global yaw scan to ±35° of the photometric winner (edge cost still does
the precise local refinement — it is precise, run13/14 proved ±1°; only its BASIN
CHOICE is scene-gameable). Stamp `yaw_anchor_deg` + provenance. **Bump
solverVersion to 8 — the alias scan then re-solves and self-heals its coloring on
the next Process.** Also reconcile the profile-gate vs solve-envelope bounds
disagreement (pitch 2.2° rejected / −3.83° accepted) in the same pass.

## Z1 probe attempt 1 (360ble9): blocked by a roster gap — fixed (9054134)

The Z1 run never reached its BLE questions: with the X already stored, the card's
only sheet path was EDIT, so `connect()` kept applying the X's SSID while the Z1 sat
in front of the operator. iOS answered `userDenied` ("failed to get user's
approval") — which it returns both for a tapped Cancel AND for an SSID not in range,
so the log read as a permissions problem rather than a wrong-network one. The BLE
wake also fired at the X's stored serial first (harmless, but 8 s of nothing).

Fixed: "Add another camera…" beside "Edit camera network…"; the sheet is mode-aware
(adding starts blank, creates a NEW roster entry, activates it — which clears the
other camera's BLE keys); join failures name the SSID and point at the switcher when
more than one camera is known.

**Z1 protocol, retry:** Add another camera… → either "Find Camera via Bluetooth"
(the Z1 advertises only after its BLE is enabled AND — per spec — after Wi-Fi-side
UUID registration; expect this to fail first time, which is itself the finding) or
manual entry `THETAYL<serial>.OSC` + serial digits → Save & Connect → once OSC is
up, BLE probe → "Register (Wi-Fi, Z1)" → Scan/tap → "Auth (BLE, Z1)" → standard
buttons. Watch for: does the Z1 advertise pre-registration? does auth unlock the v1
chars (Camera Information reads, TakePicture 0x01, NetworkType 1)? is CCv2 present
(needs ≥3.10.2)?

## Z1 BLE: root cause was OURS, and the Z1's real contract (2026-08-06, 360ble9/10)

**Root cause of "Add Camera finds the Z1 but fails to connect":** not the camera.
360ble9 shows the Z1 (serial 34103606, fw 3.60.3) connecting and serving
GetInfo/GetState/GetState2 for ~25 s while **unregistered and unbonded**. Our
readiness gate required all four CCv2 characteristics; a Z1 exposes only the
read-only subset (GetInfo A0452E2D, GetState 083D92B0, GetState2 8881CE4E,
GetOptions 7CFFAAE3, NotifyState D32CE140) and **no SetOptions or Shutter**, so the
gate could never pass, the 12 s link watchdog fired, and `cancelPeripheralConnection`
produced the log's bare "link dropped" — the missing error text is the proof it was
our cancel, since a camera-initiated drop reports `CBError.peripheralDisconnected`.
Fixed in `3c0aa18` (minimum working set + capability flags + discovery-complete
detection + model gate before the 60 s write + prefilled hand-off + Cancel).

**"No PIN on the camera screen" is CORRECT Z1 behavior, not a fault.** Spec verbatim
(theta-bluetooth-api/getting_started.md): *"RICOH THETA authenticates a central
device via Web API and Bluetooth API. The camera does not use pairing."* The official
SDK confirms the split — `ThetaBle.kt` calls `tryBond()` **only** when no UUID is
supplied (the X path); supplying a UUID (the V/Z1 path) never bonds. Never build
passkey UI for a Z1.

**The Z1's real BLE contract (spec + SDK, for the future increment):**
- Two characteristic tables: *"Auth Bluetooth Device required (V/Z1)"* = the whole v1
  family, and *"Auth Bluetooth Device not required (Z1/X)"* = Camera Control Command
  v2 only, footnoted Z1 ≥ **3.10.2** / X ≥ 2.20.1. That is exactly why our Z1 read
  identity with no auth while every v1 char and the auth char itself answered
  handle-invalid.
- Enabling control: `camera._setBluetoothDevice {uuid}` + `_bluetoothPower: ON` over
  **Wi-Fi/OSC** (X is unsupported for this command — the two auth schemes are
  mutually exclusive by model), then write that UUID to EBAFB2F0 on service 0F291746
  over BLE. Registration persists; **the auth write does NOT — it must be repeated on
  every BLE session, and again after any sleep/wake**, which makes it a step inside
  `establishLink`, not a one-time pairing.
- Wake path differs too: Z1 uses the v1 Camera Power characteristic (B58CE84C, write
  0x01), not the X's `SetOptions {"cameraPower":"on"}`.
- **Z1 SSID prefix is `YN`** (SDK `ThetaModel.kt`; X = `YR`) — our `THETAYL` guess was
  wrong and is corrected to `THETAYN<serial>.OSC`.

**Decision: ship Z1 Wi-Fi-only first; Z1 BLE is a separate, now fully-specified
increment.** The Wi-Fi path is already ready (firmware gate, SSID map, resolution-
agnostic solver + face cut), and the user's goal is a low-light comparison scan that
needs no BLE. Gate the increment on two probe answers: (1) does Camera Power wake a
sleeping Z1 after auth, and (2) does the Z1 push `_latestFileUrl` over CCv2
NotifyState? Without (2), a BLE shutter still needs an OSC round-trip for the file
URL, which erases most of the win; without (1), the increment isn't worth a
per-connection auth state machine at all.

## Processing/coloring flow model (field redesign, 2026-08-06 — 5e35144)

One mental model everywhere:
- **Automated:** structural post-processing (download sweep → calibration →
  registration → proxy) runs at SAVE and on LANDING at a location. Users never think
  about it. Late-arriving inputs (the deferred RoomBuilder's roomplan.json) simply
  make more steps achievable for the next automated pass — or for Color.
- **Color (the primary per-scan button):** "make this scan colored, whatever that
  takes" — finishes any pending structural stragglers, then (re)colors. This absorbs
  the two-click mystery (auto-process froze its step list before roomplan.json
  landed; the first Process click was silently finishing registration/proxy).
- **Long-press menu = recovery tools:** "Re-run Processing" (structural only, says
  "Nothing to process" when clean) and "Redo 360° Calibration" (strips provenance,
  re-solves). For camera-gone downloads, late roomplans, pipeline upgrades.
- **Gates stay structural:** upload/save-to-files still require post-processing
  complete and offer "Post-process Now" (structural, no color).
- Bulk edit-mode Process/Color buttons unchanged for now (power tools); if the
  single-scan model proves out, bulk Color should adopt the same
  structural-first-then-color semantics.

## PR #37 "360 updates": field-measured timing, guidance, masks (2026-08-07 → 08-15)

Nine field runs (360update1-9) drove this arc. Findings worth not re-deriving:

### Protocol timing is now MEASURED, per still, per model

| | Theta X (BLE) | Theta Z1 (OSC) |
|:--|:--|:--|
| shutter ack after tap | 164-294 ms | 382-409 ms |
| EXIF exposure (room light) | 1/30 s | 1/30 s |
| file listed (trigger_ms) | 4.2-4.8 s | 4.3 s |

Every still records `shutter_ack_ms`, `exposure_window_ms`, `exif_exposure_time_s` and
the raw motion samples, so these are re-derivable offline rather than assumed.

### The sway window ran from the wrong end, and was 30× too wide

The first cut measured `[ack, ack+1 s]`. Both halves were wrong. The sidecar pose is
sampled at the TAP and the shutter fires ~200 ms later, so **the pose error is the drift
between tap and shutter** — motion afterwards is stitch and transfer, which cannot affect
an image already captured. And the shutter is open for 33 ms, not a second.

Cost of the error, from the data: a Z1 still whose operator moved **22 cm and 36°** across
the full trigger had **2 mm** inside the true window. The old window would have flagged it.

Window is now `[tap, ack + latency allowance + exposure]` ≈ 250 ms, and the probe samples
at 50 ms (250 ms put exactly ONE sample inside the real window). Exposure is learned per
model from EXIF, so a dim room widens the guard by itself.

### "You can move" fires at exposure close, not at file landing

~0.35 s (X) / ~0.56 s (Z1) against 4.3-4.8 s — about **4 seconds returned per still**.
Holding and transferring are separate states so the UI cannot contradict the tone.
Release is idempotent and only the ack timer plays the sound, so a FAILED shot releases
the operator without claiming success.

ANSWERED (2026-08-17): the shutter instant is **not observable over BLE on the X**. A
probe polling GetState at 40 ms through four captures logged 50-56 landed reads per
still and saw only `_captureStatus: idle` / `_capturedPictures: 0` throughout — the
camera does not report a single still's shutter at all. NotifyState never pushes it
either (rounds 4-8). So ack + latency allowance is the only estimate available, and the
probe was deleted rather than left in: it added BLE traffic during the busiest moment of
a capture, which matters more than it first appeared (see below).

**BLE writes can stop being acknowledged while the link stays CONNECTED.** Same run,
suspected RF congestion from nearby work: still 1 fired over BLE with a 262 ms ack, then
stills 2-4 logged "shutter write unacknowledged" and fell back to OSC with ~3.2 s
"acks" — which are the 3 s write watchdog plus an HTTP round trip, not shutter times.
`canShutterOverBLE` reported true throughout, because characteristics were discovered and
the connection was alive; only the data path had degraded. Consequences now handled: the
sidecar records `shutter_path` so tuning data can exclude fallback stills, two
consecutive failures stop further BLE attempts for the scan (each was costing the full
watchdog to reach the same fallback), and the capture chip names the path in use.

### Still-placement rings: no third voxel grid

A 360° still sees every direction, so "is this a good spot" collapses to distance from
the stills already taken — ≤20 points and a distance test, not a coverage volume.

Two non-obvious dependencies:
- **Plane detection is OFF in a normal scan** (only enabled for ghost alignment), so
  ARPlaneAnchor floors do not exist. Floor comes from a 1 m XZ field of the lowest mesh
  vertex per cell, sampled from vertices the wireframe pass already transforms. The cell
  a point sits in WINS OUTRIGHT — a neighbourhood minimum sinks rings through the floor
  on stairs and ramps.
- **Capture height is learned per operator**, because a fixed drop is wrong for the people
  using this: operators scan from wheelchairs and at very different statures. A >15 cm
  mismatch is treated as a different person and adopted outright rather than smoothed, so
  a rig handed from a tall operator to a seated one converges in one still, and rings
  already drawn re-place themselves within half a second.

### Vision is CONFIDENTLY wrong on blank ceilings

Privacy-on runs pixelated the entire ceiling. The pipeline was correct: the projection
thresholds at 128 and the composite paints only at 255, so those pixels legitimately
cleared the bar.

A confidence test does NOT catch this — one face logged **82.4% over threshold with 55.7%
at high confidence**. `VNGeneratePersonSegmentationRequest` has no way to express "no
subject here", and a flat bright surface is the ideal trigger.

The fix is geometric, not statistical: the lens rides a rod ABOVE the operator's head, so
everyone on the floor is BELOW it (a 1.9 m person half a metre from a low 1.82 m rig
still only reaches ~+9°). "Person" above +25° is dropped when it covers >8% of the frame
— the area condition keeps it fail-closed for someone genuinely above the lens on stairs,
who is small in frame where the wash covers a third of the sphere.

Validated: still-4 mask coverage 42% → 15.7%, ceiling pixelation gone.

### Operator/rig masks, and all six cube faces

The mask is the union of a GEOMETRIC nadir cone (rod/mount/tripod hang below the camera
by construction — measured inside 17°, default 20°) and SEGMENTED people (the operator is
NOT reliably under the camera: on a tripod or a rod they sit at −30° to −60° off to one
side, which geometry cannot predict).

Emitted for every scan **regardless of the privacy filter** — this is a reconstruction
artifact, and a person is equally wrong to reconstruct whether or not their pixels ship.
White = usable, black = ignore (COLMAP ignores zero-valued mask pixels; Nerfstudio treats
1 as keep), so nothing downstream reinterprets it.

The bottom face now ships, because a precise mask replaces the blunt "discard by
construction". It is the closest geometry in the still and the best parallax available;
masked, ~80% of it survives as usable floor. **A face MUST ship with its mask** — a bare
face is worse than no face, since downstream would reconstruct the rig and operator as
scene content.

### Rig geometry: the model has no forward/back offset

Decomposing the rod direction from a measured 28.5-inch rig across five stills: the rod
tilts **11.6-14.2°** from vertical (the operator angles the iPad down to see the floor),
putting the camera **14-17 cm FORWARD** of the phone, 3 cm lateral, and 70.5 cm up —
against a 72.4 cm tape measure.

The solve WAS 4-dimensional `(dy, dLateral, yaw, pitchResidual)` with `dy` along WORLD up
and `dLateral` perpendicular to phone-forward. A forward offset is orthogonal to both and
lives in the PHONE's frame, so it rotates as the operator turns and no global constant can
absorb it — it leaked into residual and biased yaw and dLateral.

**FIXED (solver v10).** The offset is now a 3-vector in the PHONE frame rotated by the
phone pose — physically what a rigid rig is. The tape measure is directly meaningful as
‖offsetPhone‖, and tilt varying scan to scan is handled for free.

What it had been costing, measured on `staging_60172200` (five stills, 1.4-4.3° tilt):
the old and new models place the lens **11-13 cm apart per still**. Most of that was not
the forward swing itself (3.8 cm at 3° tilt) but the error the model had pushed elsewhere
to compensate — a `dy` railed 4.8 cm above the tape and a 9.9 cm `dLateral` with no
physical basis. Under the new model the lens height comes out 0.722-0.724 m at every
tilt, because the rod length is the thing that is actually fixed.

The scan that motivated it stamped `solved_postprocess, 2.92 px, converged` with `dy` 2 mm
from its wall and `elevation_offset_deg` pinned at the exact end of its sweep (-11.25°) on
all five stills. `pitchResidual` and `elevation_offset_deg` are KEPT for one solver cycle
on purpose: with no systematic error left to absorb they should collapse toward zero on
their own, and that is the falsifiable test of this model. Railed parameters are now named
in the log and stamped as `rig_calibration_railed` in every sidecar, so the next scan
answers the question directly.

### Keyboard crash: the mechanism, not the trigger

The rig-height field crashed with `_UIRemoteKeyboardPlaceholderView … no common ancestor`
from Capture AND Dashboard. First fix removed the trigger (text rewritten during teardown)
and it still crashed — and two things that fix ADDED are themselves triggers
(`ToolbarItemGroup(placement: .keyboard)` creates an input accessory; focusing in
`.onAppear` races the sheet presentation).

Conclusion: that failure family has too many entry points to dodge. **The field no longer
uses a system keyboard** — a twelve-button keypad has no first responder, no input
accessory, no keyboard-avoidance constraints, nothing to tear down. Settings opens the
same sheet, so there is ONE editor and no keyboard anywhere in this path.

## Open items (consolidated 2026-08-16)

Carried forward from the whole 360° arc, not just the last PR. Ordered by what blocks
what.

**Solver — the two known modelling gaps.** Neither is wired yet because both change the
cost function, which is the critical path; both want an offline run against the known-good
bundles (4.04 and 4.81 px RMS references).
1. *Masks are not fed to calibration.* It still uses the blunt −45° elevation cutoff. The
   larger win is not the floor it admits but the bias it removes: the operator sits at
   −30° to −60°, so roughly HALF of them is currently inside the cost function as a
   systematic attractor. Requires mask generation to move from export to Process time
   (compute once, persist in raw_data, export reuses).
2. *No forward/back rig offset* (14-17 cm measured). Re-parameterize in the phone frame —
   see the PR #37 section.

**Measurement still owed.**
3. ack→shutter latency per model (poll `_captureStatus`, or the millisecond-clock shot).
   Until then the release timing carries a 120 ms assumption.
4. Sway thresholds are UNTUNED (30 mm / 2.0°). Rod-mounted maxima so far: 7 mm / 1.43°.
   Do not tune from off-rod data — a 0.72 m rod amplifies angular sway into lens
   translation, and 1.43° there is ~18 mm at the lens, larger than the translation term.
   The honest single metric is combined lens displacement
   `translation + rigHeight·tan(angle)`, which would read ~25 mm against a 30 mm gate.
5. A HANDHELD pano to confirm whether the operator enters the nadir cone when the rig is
   carried rather than tripod-mounted. Tripod runs put them at −30° to −60°, well clear.

**Deferred by decision.**
6. Destinations roster + upload queue (S3 SigV4 + multipart resume, password-required PUT,
   Keychain, least-privilege IAM policy generator, camera-AP release before LAN upload).
   Its own PR.
7. Z1 BLE increment — gated on Camera-Power wake + `_latestFileUrl` push probe answers.
   Z1 ships Wi-Fi-only.
8. v8 keyframe-anchored yaw solver — design locked and validated offline, not yet ported.
9. Mid-scan camera-delete exposure — TABLED; fix designed (save-completion sweep +
   Process-sweep reachability + connect catch-up sweep).
10. Silent save-failure paths (`guard let pending` returns silently; the
    `isWaitingToSave` handoff) — identified in forensics, not closed.

**Hygiene.**
11. `CaptureView.body` is AT the Swift type-checker limit — adding one argument or one
    modifier fails the build outright. It wants decomposition, not another workaround.
12. Dev-mode calibration review UI is duplicated between the Dashboard card and the
    Capture overlay.
13. `ThetaBLEManager`'s header states credential readback over BLE is refused as settled;
    `ThetaBLEProbe` still frames it as an open experiment. The journal says refused —
    reconcile.
14. Cube-face overlap for splat training (below) remains untested.

## Open questions

- Insta360 SDK access: how long does the developer-agreement approval take, and does the
  iOS SDK expose still trigger + dual-fisheye download + on-device stitching, or only a
  subset?
  - The developer-agreement approval for the Insta360 SDK takes up to three working days. The iOS SDK provides access to dual-fisheye download and on-device stitching, but may not expose all functionalities available in the SDK.
- Cube-face resolution/overlap: is 90° FOV per face optimal for splat training, or do
  slightly-overlapping faces (e.g. 100° FOV) help feature matching at face seams?
- Where does dual-fisheye → equirect stitching run for Insta360 (on device, in the
  camera, or in wisescan-ingestion)?
  - The stitching of dual-fisheye images to create equirectangular panoramas for Insta360 cameras typically occurs during the image processing phase after the footage is ingested. This means that the stitching is not performed directly on the camera device itself.
- Trigger→exposure latency variance per camera: PARTIALLY ANSWERED — the ack is measured
  per still (X 164-294 ms, Z1 382-409 ms) and exposure is learned per model from EXIF.
  What remains unmeasured is ack→shutter itself; the camera's audible shutter suggests it
  is later than the 120 ms allowance. Resolve by polling `_captureStatus` over BLE during
  a capture (shooting→idle), or by photographing a millisecond clock.
- How does the coverage overlay communicate "covered by 360° still pending transfer"
  (post-process mode) vs "confirmed on device" — a third visual state or optimistic
  clear with post-scan reconciliation report?
