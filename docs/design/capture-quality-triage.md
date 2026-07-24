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
  two symptoms, one remedy (config re-run): (a) recording with dead depth — 60 fps camera
  despite the selected 30 fps format, zero mesh anchors for 36 s → **depth-start watchdog**
  (8 s, one-shot rebuild); (b) idle with zero frames flowing — tracking `.initializing`
  forever, record taps bounced endlessly → **record-tap revive** (re-run config when no
  ARFrame for >3 s). Both pending device validation.

**Not implemented (escalate if Save-Anyway scans still mis-color):** per-frame reinit-epoch
tag in transforms.json so colorize can drop pre-reinit poses.

**Lever status (2026-07-23): prompt half DONE** — the name prompt is deferred until the
save pipeline completes (world map/mesh/colors persisted, AR view downgraded; landed via
PR #26, M2-validated: the alert now presents after TEARDOWN with an instant keyboard, and
the world-map failure alert can no longer stack under it). M2 stop stalls measured
3185/1969 ms post-fix vs 7056 ms. **Remaining half: profile what holds main during the VR
teardown window itself** (bloom callback removal? RealityKit scene teardown? worldmap
archive?) — an Instruments session on the marginal iPad.
