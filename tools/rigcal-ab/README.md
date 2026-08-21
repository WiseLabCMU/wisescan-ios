# Offline A/B: photometric (ZNCC) rig solver vs the shipped edge cost

Run 2026-08-19 against 23 field bundles (X + Z1, two rig eras, including the
glass-walled room and both weak-geometry scans). `prep.py` caches each
`~/Downloads/staging_*` bundle (ffmpeg + numpy venv); `solve.py` solves every
bundle two ways and writes `results.json`.

The photometric solver is the keyframe yaw anchor grown up: unproject keyframe
depth to world points carrying gray, project into each still through the same
v14 model (`camPos = phonePos + R_WP·t_P`, gravity-leveled yaw), score
1 − trimmed-mean ZNCC per (keyframe, still) pair, operator mask honored.
Modes: `parity` = the device's bounds (tape ±3 cm along the gravity-measured
rod, ±7 cm across, yaw ±35° of the coarse basin); `free` = ±25 cm box, which
asks what the cost would do *without* the tape.

## Verdict (details in results-2026-08-19.json)

1. **Yaw: photometric wins decisively.** The glass room solves to +0.9° with no
   clamp (the edge cost needed v13's binding to avoid a 50° miss). The
   weak-geometry scan the edge cost triple-railed at +9.6° solves to +2.3° with
   a healthy 3.5° per-still spread. Per-era yaw consistency: σ 2.1° on the
   current rig, 3.6° across the mixed old-era rigs. Per-still yaw spread works
   as the quality metric (1.0–4.5° healthy, 7.5° on the weakest scans).
2. **The elevation nuisance is an edge-cost artifact.** Photometric needs
   0.0° of elevation offset on 22 of 23 bundles (1.4° on one) — INCLUDING the
   old-era scans where the edge cost railed at ±11.25°. It was never an image
   property; it absorbed mesh/model error the photometric cost never sees.
   Retire it at port time (keep writing 0 for sidecar compat).
3. **Neither cost owns the rod length — the tape does, as v14 already ships.**
   Freed, photometric biases LOW (median −3 cm, worst −9.5) where the edge cost
   biased HIGH (+8 to +10 against ground truth); similar spread (σ ~3.7 cm).
   Opposite systematic pulls, same lesson. NOTE: under a photometric port the
   rod-rail direction semantics FLIP (its pull rides the tape's lower wall).
4. **Cost:** 1–2 s per scan in interpreted Python (8k points × 5 stills);
   a Swift port drops the mesh parse, edge extraction, distance transform and
   elevation sweep entirely.

Port recommendation: yes — photometric becomes the solver (yaw + refinement
inside the tape-owned cylinder), the keyframe anchor stops being a separate
pre-pass because it IS the solver, and ~700 lines of edge/chamfer machinery
retire with the mesh dependency. Needs its own on-device validation cycle
before the edge path is deleted rather than merely bypassed.
