# Capture-Quality — Device-Test Triage

Carried-forward observations from earlier `feat/capture-quality` device runs (weak-chip
iPad unless noted). Two are **verification passes to run** before/at the PR merge; two are
**watch items** with a defined hardening lever, deliberately not implemented yet. Sibling of
the per-feature verification list in [voxel-accumulated-point-cloud.md](voxel-accumulated-point-cloud.md).

## Verify on device

### 1. Hi-res keyframe failure-path resilience — ✅ VERIFIED (2026-07-24, M2 iPad, `interrupt.log`)
Trigger a session interruption mid-scan (Control Center pull-down, app switch, or a phone
call) while pausing for keyframes. Expected: `Hi-res capture failed ... attempt N/3`
**recovers on the next pause** rather than silently degrading to 2016×1512 for the rest of
the scan; a wedged request should log the **5 s watchdog re-request**.

**Result:** stronger than expected — zero `Hi-res capture failed` lines across repeated
Control-Center + app-switch interruptions; keyframes kept firing at 4032×3024 (sharpness
98–464) straight through, watchdog never needed. But the run exposed a different
interruption problem — see item 6.

### 2. Reject-blur OFF confirmation scan — ✅ VERIFIED (2026-07-24, same run)
Flip the reject-blur setting off and confirm the reticle, keyframes, and coverage overlay
all still work. This path was **completely dead before the review fix** — worth one
confirmation scan.

**Result:** reticle, keyframes, and `[Coverage] Still overlap` logging all ran with
reject-blur OFF. No dead path.

## Watch items (lever defined, not implemented)

> **⬆ ESCALATED (2026-07-22 post-merge long run, `capqual1.log`):** recurred **mid-scan**, not
> just at bring-up — at t≈73 s of an AR scan (footprint 1.2 GB, CPU ~300%), a
> `jpeg_encode_hires 1242ms` (vs 73–90 ms for regular encodes) coincided with a sustained
> `retaining 11–13 ARFrames` burst → ARKit dropped to `limited(Initializing)`, **VIO
> reinit #2**, fps 11, ~2 s of skipped mesh integration before self-recovery.
>
> **Mid-scan lever status (2026-07-23): implemented.** Audit found most of it already in the
> branch — the hi-res encode runs on its own SERIAL `.utility` queue (`keyframeEncodeQueue`,
> never the shared ioQueue), the keyframe CIContext is `priorityRequestLow`, depth/confidence/
> seg detach-copy so pooled buffers release with the ARFrame, and `hiResCaptureInFlight` stays
> latched through the whole sharpness-gate + encode window. The one real gap: rapid shutter
> taps each re-armed a fresh keyframe budget and stacked serialized request→encode cycles
> back-to-back (heard as multiple shutter clicks) — `requestStillCapture` now refuses taps
> while a still is armed or in flight (warning haptic; reticle shows "Capturing…"). Remaining
> residue is the BRING-UP interaction below (hold-until-warm lever) — still watch-only.

### 3. ARFrame-retention burst at bring-up × early keyframe
At t=0–1 s of a scan there was a burst of `delegate is retaining 11–13 ARFrames` warnings —
the classic pool-starvation precursor this repo fights. Cause: everything piled up at once
on the weak chip — RoomPlan enabling, the segmentation model loading (316% CPU at
SEG-READY), and the first stillness keyframe firing very early (t≈3–4 s under a
held-still start) adding a **494 ms encode** into the bring-up storm. It self-recovered
(warnings stopped, tracking stayed normal, no VIO trip) and was **not seen on A12Z runs**,
so it's the early-keyframe × bring-up interaction on marginal hardware.

**Lever if it recurs/escalates:** hold hi-res keyframe requests until the session is warm
(e.g. until SEG-READY, or the first few seconds). Small change; for now, watch it.
Related: main's PR #28 flagged the same ARFrame-retention class under
`30fps + deferred-blur + personSegmentation` as a capture-perf ticket — if that ticket
opens, fold this in.

### 4. Thermal budget is the late-scan ceiling in VR mode
The device reaches `thermal=serious` by **~90 s** of VR scanning with everything running
(RoomPlan + segmentation + voxel pipeline + hi-res stills). Bloom removal (defaulted off)
helps a little GPU-side, but thermal headroom is the real budget late-scan — **voxel
decay/pack timings quadrupled under throttle**.

**Lever if long VR scans matter:** throttle the voxel pipeline cadence when
`ProcessInfo.thermalState >= .serious` (fewer decay/extract passes, same data). Parked as
a follow-up; not on the branch.

**2026-07-22 post-merge run note:** the long run (6 scans incl. one long VR scan) stayed
`thermal=nominal` throughout — voxel timings stayed 17–28 ms. The VR-mode watchdog stalls
that run were **VR-ENTER (469 ms — bloom/pipeline setup)** and **VR-EXIT + save (828 ms)**,
both sub-second transition costs on the marginal iPad, not the thermal cliff. Watch both;
the ENTER stall's lever is lazy bloom setup (it runs even though bloom defaults OFF).

### 5. Stop/save teardown main-thread stall — ESCALATING on VR
Observed across runs on the marginal iPad: **2469 ms** (AR stop, first post-merge run) →
**7056 ms** (VR stop, P1-fixes validation run). The window spans the worldmap archive
(`map load (save (about to persist))`) → VR-EXIT → session teardown, with the **naming
alert presenting over the still-rendering ARView** (the exact CONTRIBUTING anti-pattern —
"leave the capture screen first, then prompt"), `Reporter disconnected` spam, `cpu=0%`
MemDiag samples, and 1.4–1.8 s ARKit frame gaps. Post-stop so no capture data is at risk,
but 7 s of frozen UI reads as a hang. Cosmetic co-symptom: `[VR] Tracking degraded —
cleared accumulated voxels` fires during the teardown degradation, wiping the on-screen
cloud early.

### 6. OS interruption mid-recording silently corrupts the session map (2026-07-24, M2, `interrupt.log`)
A Control-Center/app-switch interruption **while the user keeps moving** forces a full SLAM
reinit (`vio_initialized(0) map_size(0)`, 7.9 s frame gap). The re-merge visually "catches
up" the mesh, but: the saved world map carried a **223 m feature cloud (max dist-from-median
152.8 m vs p99 7.1 m)** for a ~4×3 m room; scan 1's colorize frames projected from a
different frame than the re-pinned mesh (colors wildly misplaced); scan 2, relocalized
against that map, seated **~0.4–0.6 m / 20–30° off** (measured live by `[LocDiag ICP]`:
trans=37.6 cm rot=30.52° pre-record) — the exact ghost/stitch offset observed. The VIO
guard never tripped: resume reports `.initializing`/`.relocalizing`, the states the
gap-trip deliberately treats as benign recovery.

**Levers implemented (2026-07-24; app-switch trip + suspect flag device-validated runs 2–3):**
- `sessionWasInterrupted` mid-recording now trips the VIO-halt path (Save Anyway / Discard,
  `needsTrackingReset` armed) — deterministic, no gap heuristic. ✅ fires on app switch.
- **Hard-gap belt** (`vioHardFrameGapTripSeconds` 4 s): a delivery gap this large trips the
  halt regardless of how the recovery frame presents — Control Center on iPadOS fires **no
  interruption callback at all** (runs 1–3), and run 1's 7.9 s gap resumed via benign-looking
  `.initializing`.
- `sessionShouldAttemptRelocalization` → true (resume relocalizes instead of re-origining).
- Save-time **wandering-cluster check** (`LocalizationDiag.mapSuspect`: max>25 m AND
  max>5×p99) → `CapturedScan.worldMapSuspect` + `worldmap_suspect` in scan4d_metadata;
  Rescan/Connect warn before relocalizing against a flagged map; yellow rollup badge on
  location/graph tiles + per-scan explainer. ✅ flagged both polluted runs; healthy control
  maps (max 8–10 m, p99-proportional) passed clean.

**Run 2–3 addenda:**
- **CC pollutes silently**: run 3 scan 1 went suspect with *no* callback, *no* frame gap,
  fps steady 30 — the save-time flag is the only reliable net for this class.
- **Suspicion is heritable**: a rescan seeded from a flagged map re-baked its own outliers
  (62 cm / 74° mid-recording corrections → its map flagged too). Expected; the dialogs now
  say to delete flagged scans so the newest clean scan becomes the reference.
- **Wedged capture graph after idle-resume** (`FigCaptureSourceRemote err=-17281` storm):
  (a) recording with dead reconstruction — 60 fps camera despite the selected 30 fps format,
  zero mesh anchors all scan; (b) idle with zero frames flowing — tracking `.initializing`
  forever, record taps bounced endlessly → **record-tap revive** (re-run config when no
  ARFrame for >3 s; nominal mode only, safe — RoomPlan never runs there).

**Run 4 addenda (2026-07-24 evening):**
- **Live config rebuild under RoomPlan is a crasher — withdrawn.** The first-cut depth
  watchdog re-ran the session mid-recording; run 4 ended in `EXC_BREAKPOINT` inside
  RoomPlan/ObjectUnderstanding (`OUSession updateWithKeyframes`, brk #0x1 on its queue) at
  save after a meshless 60 fps scan. Replaced with a **mesh-start watchdog** (10 s, signal =
  first `ARMeshAnchor`, which subsumes dead-depth AND dead-Recon3D) that **halts via the VIO
  guard** — `needsTrackingReset` then rebuilds everything at the next record-start, the
  manual fix that always worked. Skips proxy-streaming/Lite configs.
- **Root cause of the 60 fps fallback found**: RoomPlan's internal reconfigure at
  `didStartWith` resets the video format to ARKit's default (format[0], 1920×1440@60) —
  run 4's failing scan logged the semantics re-assert firing but the format stayed 60 and
  Recon3D never initialized. `reassertFrameSemantics` now **re-forces the selected video
  format in the same run()** (respects the dev-mode format override), so the state should
  be prevented, with the halt as backstop.

**Run 6 (2026-07-24, M2, link-adjacent chains):**
- **Mesh-halt backstop validated live**: post-idle wedge recurred *despite* the 30 fps
  re-assert (graph wedge ≠ format-only) — watchdog halted at 10 s, `needsTrackingReset`
  armed, next scan clean. Exactly the designed recovery.
- **NEW CRASH, fixed**: `NSInvalidArgumentException "Invalid number value (NaN) in JSON
  write"` from `writeTransformsJSON` during a thermal=serious link-adjacent stop —
  JSONSerialization raises an ObjC exception for non-finite numbers that Swift `try?`
  cannot catch. All FrameCaptureSession JSON writers now sanitize payloads (non-finite → 0)
  and **log the offending key paths**, so the next occurrence identifies the true NaN
  source (pose vs intrinsics vs sharpness/exposure).
- **Thermal ceiling observation** (items 4/5 territory): the link-adjacent auto-save ran
  >60 s under thermal=serious / CPU ~300% / ARFrame-retention storm while recording
  continued ("Saving scan… do not move" held past a minute). The crash cut it short, so
  unclear if it would have completed; watch on the next long chain.

**Run 11 (2026-07-24, M2, link-adjacent) — startups steady, detector catches a THIRD
corruption class:**
- All record-starts clean across the link-adjacent runs (run-10 stale-status fix + run-8
  resume fix validated again).
- Last scan (96 frames, longest of the arc) flagged suspect on a **real 91.8 m outlier
  cluster (p99 4.9 m, 19×)** — with tracking `.normal` throughout, zero snap corrections,
  zero skipped integration, thermal nominal. A silent excursion in the SnapTracker's
  documented blind spot (loop-closure under continuous normal tracking) that ONLY the
  save-time detector can see. A 10% battery dialog appeared mid-scan (ARFrame-retention
  burst present, consistent with Low Power Mode throttling) — correlation unprovable from
  console logs, so `low_power_mode` is now recorded in scan4d_metadata at capture stop.

**Run 10 (2026-07-24, M2) — the bounce loop's THIRD face, fixed:**
- Loop recurred with the session **healthy and un-paused**: the post-save stats reset
  hardcoded `scanStats.trackingStatus = .notAvailable`, and the UI copy only refreshes on
  ARKit *transitions* — a teardown that leaves the live session in `.normal` throughout
  (this run: zero transitions logged post-save) never corrects the lie, so the record gate
  bounced forever against a healthy session. The revive was RIGHT to stay silent (it checks
  the real session). The user's Analyse pass escaped it by forcing real transitions.
- Fix: the stats reset no longer touches `trackingStatus` — the last pushed value stays
  truthful, and any real tracking restart still updates via its transition. The three loop
  faces are now: dead graph → revive rebuild; cold-stuck session → revive reset;
  stale UI copy → removed. Battery-resume fix held again this run (post-resume scan clean).

**Run 9 (2026-07-24, M2):**
- **Battery-resume fix validated 2/2** — post-idle scans just worked (no wedge, no halt,
  healthy maps).
- **Last gap closed**: after the final save the session sat in cold tracking for minutes
  *with frames flowing* — the record gate bounced and the revive's dead-graph branch
  correctly didn't apply (run-3 loop, frames-alive variant). The revive now has a second
  branch: frames flowing + tracking cold >5 s + was-ready-once + **no loaded world map**
  (never yanks a rescan/link relocalization; cold-start warm-up can't trip it) → re-run
  factory config with `.resetTracking + .removeExistingAnchors`. Pending device pass.

**Run 8 (2026-07-24, M2, timing sweep — WEDGE ROOT-CAUSED & FIXED):**
- The idle wedge reproduced **deterministically**: every battery-resume recording (×4) went
  meshless and the tuned mesh-halt caught each one at 10 s post-settle (no false positives
  this run); every post-halt retry recovered via `.resetTracking`. Frames always flowed, so
  the revive path never applied.
- **Root cause was the battery-resume itself**: it re-ran a *bare*
  `ARWorldTrackingConfiguration()` — ARKit's default 60 fps format, not our selection — with
  *no reset options*, carrying the Fig-wedged graph into the next recording. Resume now runs
  the factory config with `[.resetTracking, .removeExistingAnchors]` — identical to the
  recovery path that worked 100% of the time; nominal mode has nothing to preserve.
- Expected next-run behavior: post-idle scans just work; the mesh-halt returns to being a
  rare backstop; the record-tap revive becomes near-unreachable (kept as final belt).

**Run 7 (2026-07-24, M2 hot, idle-tap sequence):**
- Battery **resume path preempted the wedge** (frames flowing by the record tap), so the
  revive correctly no-op'd — its positive case stays unexercised (needs the intermittent
  Fig storm); bounded risk, nominal-only.
- **Mesh watchdog false positive, fixed**: hot post-idle start took ~4 s of VIO init and the
  user (primed by "hold steady") stood still — the 10 s budget expired as the first anchors
  landed → spurious halt + mapless Save Anyway. The budget now starts at the recording's
  **first `.normal` tracking frame**, so VIO init doesn't count against it; a truly dead
  reconstruction (run 6: `.normal` in ~2 s, meshless forever) still trips.

**Run 5 (2026-07-24, marginal iPad): all green.** Format re-force logged `@ 30fps` on all
5 record-starts (AR + VR); interruption trip fired mid-rescan; no meshless scans, no
watchdog/halt false-trips; suspect detector stayed silent on every clean save; **delete
flagged/interrupted scan → rescan from the clean base validated** (healthy map, no
warning). Remaining nice-to-have: record-tap revive confirmation on M2 (idle-wedge state
only ever reproduced there).

**Not implemented (escalate if Save-Anyway scans still mis-color):** per-frame reinit-epoch
tag in transforms.json so colorize can drop pre-reinit poses.

**Lever status (2026-07-23): prompt half DONE** — the name prompt is deferred until the
save pipeline completes (world map/mesh/colors persisted, AR view downgraded; landed via
PR #26, M2-validated: the alert now presents after TEARDOWN with an instant keyboard, and
the world-map failure alert can no longer stack under it). M2 stop stalls measured
3185/1969 ms post-fix vs 7056 ms. **Remaining half: profile what holds main during the VR
teardown window itself** (bloom callback removal? RealityKit scene teardown? worldmap
archive?) — an Instruments session on the marginal iPad.
