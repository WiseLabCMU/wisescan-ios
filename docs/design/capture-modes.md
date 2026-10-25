# Capture modes: room scan and focus scan

Status: implemented on `exp/arkit-capture-mode` (2026-10-23), not yet built or tested on a device.
Supersedes the AR Capture experiment. Requirements: REQ-035 (focus scan), REQ-036 (automatic room
stills), REQ-037 (region import).

A rescan now offers two modes. Both relocalize into the latest room scan's world map exactly as a
rescan does today, then diverge at Start.

- **Room scan** (the existing rescan): mesh, RoomPlan, coverage overlay, and photos for a
  room-level "what does it look like now" pass, enough to paint the mesh and feed a VLM, not
  enough to reconstruct.
- **Focus scan** (new): full-resolution stills of one box-shaped region, at a chosen level of
  detail, from "a few photos of what was left on the table" to splat-grade coverage. No mesh, no
  RoomPlan: ARKit tracking, LiDAR depth, the stills and their poses.

## What the AR Capture experiment established

- ARKit stills are 12MP on both test devices (M1 iPad Pro, iPhone 17 Pro Max); the formats offer
  1920x1440 and 4032x3024 only.
- Exposure is the blur problem. Uncapped, ARKit's auto exposure reaches 1/30 s. A cap through
  `configurableCaptureDeviceForPrimaryCamera.activeMaxExposureDuration` works: 1/120 was blur-free
  at a slow pace; short exposure (1/500 floor, ISO ceiling 800) was blur-free at about 2.4 times
  the still rate, with no banding found and a measurable loss of fine texture at high ISO.
- The blur gate is image motion as an angle (0.9 mrad): the larger of a pose term (rotation and
  sideways motion over the near LiDAR depth) and the gyro's 50 ms peak rate.
- Every still logs the gyro rate at its own timestamp, and every frame's delegate work is timed.
- The video-stream frames the room scan exports today are not usable for reconstruction: they
  share auto exposure up to 1/30 s.

## Decisions (2026-10-23)

1. A focus scan always has a box. The box bounds downstream work (a splat crop, a VLM's attention)
   and makes coverage measurable; without one there is nothing to measure against.
2. Region drawing MVP: in the scan viewer, tap a RoomPlan object to take its box plus a margin, or
   tap the mesh to drop a default box; then sliders for size, height, yaw and position. Direct
   drag handles come later.
3. Detail levels MVP: Check, Detail, Splat (table below). Tune later.
4. The room scan drops video-stream images entirely. Stills fire automatically at 12MP; the
   stream-frame path stays only as the fallback when stills keep failing.
5. The screen tap fires the 360° camera only, and only with a rig connected.
6. Privacy blur for focus stills runs at export, like every other capture source. With nothing
   filtered during capture, the toggle stays live through a focus scan and its value at Stop counts.
7. Regions are not catalogued yet. A focus scan carries its own region; scans of the same table
   are not grouped. Focus scans sit in the same list as room scans, marked partial, with a card
   that shows the previous room scan's outline with the box and one photo.

## Shared foundation

- **Capture mode.** `ScanStore.captureMode` (room or focus, with the region and detail level)
  replaces the experiment's `stillCaptureMode` flag. `CaptureView.isCapturing` (recording or
  capturing stills) is the one state every pre-record safeguard reads: the ghost chip,
  Re-relocalize, the relocalization watchdog and Try Again, the ghost-reload path, leaving the tab.
- **Configuration.** Every `session.run` in `ARCoverageView` builds its configuration through one
  function for the active session role, so no re-run can drop scene depth or the mode's semantics.
  (The AR Capture depth loss came from a re-run with the pre-record configuration.)
- **Exposure policy.** `CaptureExposurePolicy` owns the cap: short exposure (1/500 to 1/120 s by
  the light; in dim light it is the 1/120 cap, so there is no separate fixed mode or field switch),
  applied at Start, re-checked every 0.3 s and re-applied if a session re-run reset it (RoomPlan
  re-runs the session), and restored to the device default at Stop. Both modes use it.

## Focus scan

### Region

A gravity-aligned box: centre (m), yaw about +Y (rad), size (width x height x depth, m), label,
source (`user`, `roomplan`, `import`), detail level. Persisted in metres in the frame of the mesh
it was drawn on, which is the original scan's canonical frame when the viewed scan's registration
was applied. Schema: `schemas/focus_region.schema.json`.

Frames. The viewer draws `mesh.obj` shifted by the canonical room centre `c`, so
`box_mesh = translate(c) * box_scene`. The capture session relocalizes into the latest room scan
`L`'s world map, whose raw frame is `L`'s capture frame, so the box in the session's world is
`inverse(T_L) * box_mesh`, with `T_L = SaveRegistration.appliedTransform(L)` (identity when none
was applied). Before Start the box takes the ghost's seat (auto-align or manual nudge); at Start
the ghost is removed and the record-start bakes move the world onto the ghost, so the box is fixed
at the seat left over (identity after a bake).

### Capture

- Stills fire only while the box is in view: its centre projects inside the image and its
  projection covers at least a minimum share of the frame.
- Blur gate and exposure: as established above.
- Coverage: view directions from the box centre, binned by azimuth (12) and elevation (3 bands).
  Shown as a 2D dial overlay (the AR view only renders opaque unlit geometry reliably).

| Level | For | Spacing | Target | Ends |
|---|---|---|---|---|
| Check | "which tools are on the table" | 25° | 5 stills | by itself at the target |
| Detail | a close look | 12° | 30 stills | user stops |
| Splat | reconstruction | 5° | 150 stills | user stops |

### Result

A `CapturedScan` with `kind = focus`, the id of the room scan whose map it used, and its region.
Its folder holds `focus_capture/` (the AR Capture dump: `photos/`, `photo_depth/`,
`photo_confidence/`, `photos.csv`, `frames.csv`, IMU logs, `events.log`, `manifest.json`,
`world_map_registration.json`), `focus_region.json`, and `thumbnail.jpg`, the best still: the one
whose view puts the box nearest the image centre, among the sharpest at capture.

Focus scans never become a relocalization source and are skipped by everything that assumes a
mesh: rescan's map choice, the original-scan lookup, post-processing, colouring, the history
scrubber, the combined view and mesh exports. Their actions: view, Save and Upload (the focus
capture zip, person blur applied), Delete.

### Region import (VLM entry)

A downstream processor defines a region as `focus_region.json` (location id, box in the canonical
frame, label, detail level, source `import`). The app accepts it through a deep link
(`scan4d://focus-region?data=<base64url JSON>`) or a file picked in the Focus sheet, and opens the
focus capture with the region loaded. Delivery from the server (polling) waits for REQ-019/020.

## Room scan

- Stills fire automatically at 12MP under the focus scan's blur gate and exposure policy, spaced
  at 15° of turn or of parallax at the near depth, one in flight.
- Video-stream frames are no longer saved (fallback excepted).
- The amber photo-coverage overlay fills from the automatic stills; the coach asks to slow down
  over amber instead of holding still and tapping. Mesh colouring uses the stills, so grey areas
  are the coverage gaps.
- Protecting tracking: no stills for the first 10 s of recording; encodes at low priority with one
  waiting at most; back off when ARKit frames arrive late, the delegate's work climbs, or thermal
  state reaches serious; stills only while tracking is normal. The per-frame work timing covers
  the room scan, so the first capture measures the cost.

## As built (where it differs from the plan above)

- **Configuration.** Not one builder: `Coordinator.runSession` wraps every `session.run` in
  ARCoverageView and re-inserts the active `SessionRole`'s frame semantics into whatever
  configuration it is given. The existing configuration paths (RoomPlan's re-runs, live-config
  tweaks) stay as they were; re-running a session under RoomPlan has crashed ObjectUnderstanding
  before, so they were not restructured.
- **The 360° rig keeps its tap.** With a Theta connected, the tap still arms a phone still with the
  360° still: the rig calibration needs the co-timed pair. The stillness reticle and chime follow.
- **Room-scan spacing** is 15° of turn or parallax, or 0.5 m walked, one request at most every 0.5 s (2 s when hot). On the rig, a held pause belongs to the tap (no automatic still while confirmed still), and a tap during an automatic still in flight adopts it.
- **The map's frame is a precondition.** The region and every focus still must be in the room
  scan's frame, so the session tracks whether it is in it (`Coordinator.inMapFrame`: relocalizing
  then normal since tracking last initialized; any tracking reset clears it). The box exists only
  then: a world anchor added before relocalization stays in the provisional frame, which put the
  box about 10 m off after a tracking loss and a Re-relocalize while the ghost, which already
  waited, sat right. Start waits for it too (`ScanStore.sessionInMapFrame`); a rescan may start
  while relocalizing because its save re-registers the mesh, but a focus scan has nothing to
  re-register. Mid-capture, tracking that comes back without relocalizing into the map, an
  interruption or a 4 s frame gap stops the stills (`frame_lost` in the manifest) and the capture,
  keeping the stills taken before it. A relocalization back into the map (Start's own re-run can
  go through one) is not a loss: stills are only held while tracking is not normal.
- **Focus-scan region test** is LiDAR-based: the depth along the image centre and four inner rays must land in the box (a large box seen in part, from inside it or from under a desk counts); the box centre in frame is only the no-depth fallback. Spacing is a turn, parallax at the near depth, or an orbit around the region.
- **Coverage dial** cells: 12 sectors of azimuth around the region's own axes x 3 elevation rings
  (below 20°, 20 to 50°, above 50°).
- **Focus card**: the best still (sharp at capture, region share of the frame nearest 35%) and the
  parent room scan's existing preview image. Drawing the box onto that preview is not done.
- **Not done**: drag handles on the box; a catalogue of regions; server delivery of regions.

## Phases

Each phase is one commit and builds on its own.

1. Foundation: capture mode, one capturing state, configuration builder, exposure policy. No
   behaviour change.
2. Data model: scan kind, parent map, region; focus scans skipped where they don't belong.
3. Focus capture: region gate, detail levels, coverage dial, box in AR, save as a scan, the card
   and its actions, export with person blur. Fixes keyframe frustums drawn without registration.
4. Region drawing MVP in the viewer, and the Rescan sheet.
5. Room-scan stills.
6. Region import.
7. Docs: REQUIREMENTS, SCAN_GUIDANCE, the in-app User Guide, README, APPSTORE, PRIVACY, schemas.
