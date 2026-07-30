# 360 Branch Device Test Plan — 2026-07-30

Branch: `feat/still-source-360` @ `HEAD` (includes calibration format downshift +
360° source chip). Device: M2 iPad + Theta X on rig (Z1 if
charged). Enable **Developer Mode + Perf Diagnostics** before starting — several tests
are decided by `PerfDiag` log lines. Save console logs per run to `~/Desktop/` as usual.

**Heads-up before the first run:**
- Your stored rig profile **will not load** after this build (deliberate: the
  `residualCm → residualPx` rename invalidates old squared-unit values). The Dashboard
  card shows "not calibrated" — that's expected, and Test 1 recalibrates.
- Keep the Theta **powered on between calibration positions** — shots now stay on the
  camera until the solve-time batch download.
- Residuals are now **px RMS** (green ≤ 1.4, yellow ≤ 2.2). A good rig calibration should
  land in the same color band it used to — the thresholds were √-converted, not re-tuned.

---

## 1. Rig calibration — new batch flow + timing numbers (primary)

1. Dashboard → Re-calibrate → capture 3 positions (walk ~2–3 m between, pause, tap).
2. **Feel check**: after each tap the button should free as soon as the camera finishes
   its stitch ("Capturing — hold steady…" → button ready), with **no download wait**.
   Walk immediately — that's the point of the change.
3. **Card check**: after still 3/3 the solving card should step through
   "Downloading still 1/3…" → "Finding edges in still 1/3…" → … → "Solving rig
   parameters…" → review card with a px residual + green/yellow/red dot.
4. Accept. Card shows "Calibrated just now (X.X px residual)".

**Collect from the log (grep `[RigCal]`)** — these decide the GPU question:

| Stage | Line | Expected ballpark |
|---|---|---|
| Format downshift | `still format downshifted 11008×5504 → 5504×2752` | at session start (X only; Z1/V no-op) |
| Mesh-edge extract | `mesh edges: N edges from M verts in XXXms` | < 2000 ms (overlapped w/ stitch — free unless it exceeds stitch) |
| Download ×3 | `download i/3: NNNN KB in XXXms` | ~3500 KB, well under 1 s each (was ~11 MB) |
| Edge detect ×3 | `edge detect i/3: XXXms` | ~200–500 ms each (15 MP decode) |
| Solve | `solve: XXXms, N iterations` | ~1000–2000 ms |
| Format restore | `still format restored to 11008×5504` | at pipeline entry AND after cancel |

**Format-restore check (important)**: after calibration completes (and once after a
mid-session Cancel), confirm the restore log line fired and the Dashboard resolution
picker still shows the full scan size; then verify the next SCAN still is full-res
(file size ~11 MB in `equirect_stills/`). A camera stuck at 5.5K would silently degrade
scan texture quality — that's the one regression this feature could cause.

**Stitch-time comparison**: note the "Capturing — hold steady…" duration per position —
at 5.5K the X's in-camera stitch should be noticeably shorter than the ~4 s you're used
to at 11K. This number decides whether the downshift stays.

Decision rule afterward: if solve > ~2 s or extract > stitch time on a big mesh, we do
the Accelerate/Metal solver work; otherwise the batching already took the win.

## 2. Calibration failure paths (findings #10 + batch recovery)

1. **Mid-capture**: start a capture, power the Theta off during "Capturing — hold
   steady…". Expect an **orange error on the card** (not a silently reset button), and a
   working retry after the camera is back.
2. **Batch download failure**: collect 3 stills, then power the Theta off before/during
   "Downloading still 1/3…". Expect retries (~3 s), then a `.failed` card saying the
   shots are still on the camera. Power the camera on, re-run calibration end-to-end.
3. **Cancel during solve**: run to "Downloading still 1/3…" and hit Cancel — the card
   must return to idle and STAY idle (no zombie review card seconds later).

## 2b. 360° source chip (new)

With the Theta connected (wearables NOT connected — the chip shares that corner), the
Capture tab should show a top-right chip: model + serial, and a calibration line —
green/yellow "Calibrated · X.X px" after Test 1, gray "Rig prior — not calibrated"
before it. During Test 3's forced drift, the chip must turn orange "Rig may have
shifted" and STAY orange for the rest of that scan (the 5 s toast is the transient
signal; the chip is the persistent one). Also verify the serial-mismatch line if you
have a second Theta: connect the other camera after calibrating → red "Calibration
from another camera".

## 3. First-still drift spot-check (px units)

1. With the fresh calibration accepted, start a normal 360 scan → first still: **no
   drift toast** expected; log shows `Spot-check: live residual X.X px RMS vs stored…`.
2. Loosen/rotate the phone in the clamp noticeably (~5°+), scan again → expect
   *"⚠️ Rig may have shifted — residual drifted from X.X → Y.Y px"*. Non-blocking.
3. Re-seat the phone, recalibrate (or accept drift for the geometry test below and
   recalibrate after).

## 4. Cube-face geometry validation (the open orientation check)

1. Scan a room with 2–3 stills; before each trigger, note the phone's compass/visual
   heading (e.g. "facing the whiteboard").
2. Export Scan4D; inspect `images/` + `cameras/`:
   - `still_0000_front.jpg` content matches the phone's heading at that pause.
   - `left`/`right` faces are on the correct sides (**not swapped**), `up` is ceiling.
   - No mirroring (text/signage in faces reads correctly).
   - Camera JSONs: `camera_pose_source` = `rig_calibrated` (calibrated run) and
     `still_source` = the Theta model; `rig_calibration_residual_px_rms` present in the
     equirect sidecars.
3. If yaw is consistently off by a fixed angle: that's `rigYawOffsetDegrees` /
   calibration territory (note the angle). If faces are mirrored or L/R swapped: sampler
   sign bug — capture the export and stop there.
4. Drop the faces + poses into the downstream pipeline (Polycam-format consumer) and
   confirm they register against the mesh.

## 5. Z1 leveling validation (if available)

1. Connect Z1 — firmware gate should pass (≥ 3.00.1) and force top/bottom correction;
   expect the connect-time "assumed level" warning.
2. One scan with stills → export: faces present, `camera_pose_source` ends in
   `_unvalidated_leveling`.
3. Inspect equirects + front faces: horizon level? If yes across a few stills, we
   promote Z1 to `.validated` (one-line change) next session.

## 6. Privacy invariant on the faces path

1. Privacy Filter **ON**, second person in view of the 360 (ideally behind the operator):
   export → the staged equirect is blurred AND **all 5 cut faces inherit the blur**
   (faces are cut from the staged image — verify no unblurred face sneaks out).
2. Privacy Filter **OFF**: warning pill expands with the 360 note ("ALL directions…");
   export logs the consent line, `scan4d_metadata.privacy_filter = false`, stills stage
   unblurred. Toggle must be locked while recording.

## 7. Export progress phases (ported UI, 360 stages)

During save/upload of a stills scan, the scan-card pill should show labeled, moving
phases (Privacy blur i/n → Cube faces i/n → Zipping…) with a real meter — not a stuck
"Converting…". Bulk upload from a location: per-card phases visible.

## 8. Regression smoke (10 min)

- One plain non-360 scan: save → postprocess → recolor → export → upload. (Shared
  `ScanExportManager` paths changed for #9; colorize consensus-median is also new
  from main.)
- One rescan/adjacent link to confirm nothing in the interruption-hardening arc
  regressed on this branch.

## Skip / don't chase

- A12Z marginal iPad: RoomPlan/OU crashes there are environmental (pre-Apple7 GPU UB) —
  don't burn rig time on it.
- "Motion still breaks" in old-scan previews: capture-era pose data, not this branch.

## What to bring back

- Console logs per run (`~/Desktop/…`), especially the `[RigCal]` table from Test 1.
- The Test 4 export bundle (or at least `cameras/*.json` + one face set) if anything
  looks swapped/mirrored.
- Verdicts per section — Tests 4 and 5 gate the remaining P3 items (settings UI,
  coverage marking, BLE trigger come after geometry is proven).
