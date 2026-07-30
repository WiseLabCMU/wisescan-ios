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

### Solver: 4 DOF, on-device (Accelerate/simd)

With the Theta's zenith correction handling roll/pitch (validated for Theta X), the
unknowns reduce to **4 parameters**:

1. **`dy`** — vertical offset (rod height along gravity)
2. **`d_lateral`** — horizontal offset (phone clip distance from rod axis; typically ~2 cm)
3. **`yaw`** — rotation around the vertical axis
4. **`pitch_residual`** — small pitch correction for imperfect zenith compensation

**Initial guess** from the mechanical prior: `dy` = measured rod length,
`d_lateral` = measured clip offset, `yaw` = 0 (lenses aligned with phone),
`pitch_residual` = 0. The solver (Nelder-Mead simplex or Levenberg-Marquardt on a
4-parameter cost function) minimizes the distance between mesh edges projected into the
equirect at the candidate rig transform and Canny edges detected in the equirect image.
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
> **Leveling gate (2026-07-28):** face poses assume zenith-corrected (level) panos, so the
> exporter gates on the sidecar's camera model — Theta X: validated; Theta Z1: leveling
> hardware exists but unvalidated → faces emit with `camera_pose_source =
> "rig_prior_unvalidated_leveling"` + a warning; unknown models: NO pose-bearing faces
> (equirect archives; connect-time warning on the Dashboard card) until a gyro-metadata
> compensation feature lifts the gate.

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

