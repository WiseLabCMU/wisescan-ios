# Capture-Quality — Device-Test Triage

Carried-forward observations from earlier `feat/capture-quality` device runs (weak-chip
iPad unless noted). Two are **verification passes to run** before/at the PR merge; two are
**watch items** with a defined hardening lever, deliberately not implemented yet. Sibling of
the per-feature verification list in [voxel-accumulated-point-cloud.md](voxel-accumulated-point-cloud.md).

## Verify on device

### 1. Hi-res keyframe failure-path resilience
Trigger a session interruption mid-scan (Control Center pull-down, app switch, or a phone
call) while pausing for keyframes. Expected: `Hi-res capture failed ... attempt N/3`
**recovers on the next pause** rather than silently degrading to 2016×1512 for the rest of
the scan; a wedged request should log the **5 s watchdog re-request**.

### 2. Reject-blur OFF confirmation scan
Flip the reject-blur setting off and confirm the reticle, keyframes, and coverage overlay
all still work. This path was **completely dead before the review fix** — worth one
confirmation scan.

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

**Lever status (2026-07-23): prompt half DONE** — the name prompt is deferred until the
save pipeline completes (world map/mesh/colors persisted, AR view downgraded; landed via
PR #26, M2-validated: the alert now presents after TEARDOWN with an instant keyboard, and
the world-map failure alert can no longer stack under it). M2 stop stalls measured
3185/1969 ms post-fix vs 7056 ms. **Remaining half: profile what holds main during the VR
teardown window itself** (bloom callback removal? RealityKit scene teardown? worldmap
archive?) — an Instruments session on the marginal iPad.
