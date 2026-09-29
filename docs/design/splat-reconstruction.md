# Design: Splat Reconstruction from Scan4D Captures

**Status:** Findings and recommendations (2026-09-29)
**Scope:** Training Gaussian splats from the Nerfstudio export, with LichtFeld Studio as the primary trainer and Nerfstudio as the secondary one.
**Evidence:** Four captures of the same lab room (`CEE18488`, `68DD2EBE`, `FE934DEC`, `35B52835`). Quality verdicts are visual A/Bs by one reviewer; numbers are measured. The [Evidence](#evidence) section maps each claim to its runs.

## Bottom line

- **Sharp views per surface point are the limit, not the priors.** In `35B52835` a typical point is seen by 8 frames, only 5 of them sharp, and 2 of them 12 MP stills. Only 16% of points have 10 or more sharp views. A photogrammetry rig with hundreds to thousands of shots, and no depth or monocular priors, resolves thin cables that we lose.
- **Priors compensate for sparse views.** MoGe monocular normals are the most valuable prior. LiDAR depth helps overall but fattens thin objects.
- **ARKit poses are good to about 1.6 px** (COLMAP reprojection). Refining them gains only a little.
- **Most mesh-derived tooling from August and September is not needed.** That covers mesh-rendered normals, the prior gate, culling, hole fill and normal-weight tuning.

## Downstream pipeline

Scripts live in `tools/scan4d-to-nerfstudio/`, with the pose-refit and depth-mask steps under `prototypes/`. Never modify the pristine `staging_*` export. Build variants as copies, using hard links for shared files.

1. **Seed cloud.** Run `meshrender.py <bundle> --mesh mesh.obj --roomplan roomplan.json --floor full --ceiling measured-depth --seed sparse_pc.ply --render-depth nolidar --normals skip`. With `--normals skip` it writes no normal maps and only ray-casts frames that lack LiDAR. The seed is required: without `ply_file_path`, LichtFeld starts from random points and silently skips the depth loss. The script imports `fillholes.py` and `pngio.py`.
2. **MoGe normals.** Run `LichtFeld-Studio preprocess <bundle> --mode normals`, which takes about a minute on the GPU. The training log must show `Normal maps available for N/N`.
3. **Pose refit (optional, a small gain).** Run `prototypes/colmap_refine.py <bundle> <work>` for features, pose-neighbour matching and triangulation with ARKit poses fixed. Then run `prototypes/refine_perimage.py <work> <bundle>/transforms.json <out>`, which refits each frame against those points with no global drift. Together they take about 5 minutes, mostly on the CPU. The COLMAP step deliberately stops before a free bundle adjustment, which drifts (4% scale plus bending) and would fight the metric depth.
4. **Depth consistency mask (optional, the current default).** Run `prototypes/depth_normal_mask.py <in> <out> 30 1 <mesh_filled.obj>`. It drops confidence-0 depth, and depth whose LiDAR normal disagrees with MoGe by more than 30° unless it agrees with the ARKit mesh within 20°. It keeps about 65% of depth. The result has cleaner surfaces and more correct opacity, but loses the thinnest cables and tripod legs.
5. **Train.** Run `LichtFeld-Studio --headless --use-depth-loss --use-normal-loss --max-width 0 --iter=30000` at default weights. Add `--mask-mode ignore` only when `masks/` exists.

## What was tried

| Change | Verdict | Evidence |
|---|---|---|
| Mesh-rendered normals | Superseded (indirect) | No direct A/B against MoGe; consistency-only matched the mesh-normal runs on thin objects, and MoGe beat consistency-only |
| Depth-normal consistency term only | Worse | Removing MoGe was clearly the worst run |
| LiDAR depth loss | Keep | Removing it was worse |
| Normal-weight sweep and prior gate | Dropped | Erased thin objects; the tuning metric was circular |
| Post-train culling (distance, free space) | Dropped | Deleted real content; under 1% floaters |
| Blur filtering of stream frames | Marginal | Filtered `FE934DEC` looked about the same |
| Snapping poses to the ARKit mesh (ICP) | Worse | Frames already agreed to 1.3 cm; ICP added about 1° of rotation noise, roughly 13 px |
| Splatfacto pose optimizer | Diagnostic only | Over 70 minutes at 100% GPU; its camera moves did not match COLMAP |
| COLMAP drift-free refit | Slight gain | Reprojection improved from 1.6 px to 1.3 px |
| Depth consistency mask | Trade-off | Cleaner surfaces, loses the thinnest objects |
| Floor and ceiling depth quads | Niche | Only fill frames without LiDAR (360° cube faces) |

## Gotchas

- **LichtFeld treats poses as hard constraints.** It has no pose optimisation.
- **MRNF decays every Gaussian's opacity at each refine step,** whether or not a camera sees it. Surfaces seen by few frames get pruned: `FE934DEC`'s ceiling was in view of 27 frames from two spots and trained to a transparent haze, even from its own training cameras.
- **`--mask-mode ignore` aborts when `masks/` is missing.** That is the case when the privacy filter is off.
- **Normal auto-generation can be silently off.** Pre-generate the maps with `preprocess`.
- **MoGe infers at 518 px,** so still resolution helps only the photometric loss.
- **ARKit depth is weakest exactly at detail.** 25% of depth pixels are confidence 0, rising to 82% at depth edges. LichtFeld ignores the confidence maps.
- **Nerfstudio 1.1.5 in `nerfstudio:blackwell` needs workarounds.** It needs a Pillow patch and `TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD=1`, and splatfacto cannot resume mid-densification.

## On-app recommendations

The export keeps changing representation, never information. Opinionated stages such as seeding, masking and filtering stay downstream.

1. **More sharp views per point (highest impact).** Stills are the sharpest data, but a typical point gets only 2. Options: fire stills automatically during slow movement instead of only on a tap, allow more than one still per stillness pause, and cut the high-res encode stalls on slower iPads. Use the voxel coverage grid ([still-source-360.md](still-source-360.md)) to target 10 or more sharp views per voxel from varied angles.
2. **Tighten the stream motion gate.** It currently rejects only above 0.5 rad/s (about 30°/s). At fx ≈ 1518 px and 1/60 s, that admits about 13 px of smear, while roughly 5°/s keeps it under 2 px. Alternatively, measure sweep-frame sharpness the way stills are measured and replace blurry frames.
3. **Coach coverage.** Capture ceilings and tall surfaces from several standing spots. Orbit small and thin objects at close range from two or three heights.
4. **Keep exporting** confidence maps, the mesh, face labels and `registration.json`. The pipeline uses all of them.
5. **Not needed:** re-expressing poses relative to anchors, and fixing still poses. COLMAP shows no drift between frames, and every still is within 3 px.

Open question, which depends on the feature-point export that is not yet on `main`: keying `feature_points.ply` as `ply_file_path` would let app-only bundles use depth without the meshrender step. It is untested whether the feature points are dense enough for LichtFeld's depth anchoring, which needs at least 256 points per camera.

## Next experiments

1. **Dense-still test.** Capture 50 to 100 sharp stills of one cluttered corner (cables, tripod) from varied angles and heights, then train the refit and masked variants. This shows whether view density recovers thin objects and how many views it takes.
2. **Ceiling decay test.** Retrain `FE934DEC` with `--config staging_FE934DEC_mono/lfs_no_opacity_decay.json`, which sets `opacity_decay` to 0, to confirm the decay explanation.
3. **LichtFeld features worth upstreaming,** if the dense-still test confirms the view-density limit: reading confidence maps, an edge-aware depth loss (as in DN-Splatter), and camera pose optimisation.

## Evidence

Runs are under `4dscans/runs/` and bundles under `4dscans/`. "Visual" means one reviewer compared splats side by side in LichtFeld; no run had a held-out metric. All captures are of the same lab room.

| Claim | Compared | Basis |
|---|---|---|
| MoGe beats consistency-only | `68DD2EBE_moge` vs `68DD2EBE_consist` | Visual: cleaner edges on monitors and square furniture |
| Both priors help, MoGe most | `35B52835_colmap` > `35B52835_colmap_nodepth` >> `35B52835_colmap_nomoge` | Visual |
| Pose refit helps slightly | `35B52835_colmap` vs `35B52835_mono` | Visual ("by a hair"); COLMAP reprojection 1.6 px to 1.3 px |
| Mesh-snap pose fix hurts | `35B52835_posefix` vs `35B52835_mono` | Visual; frame-to-frame LiDAR agreement unchanged at 1.3 cm |
| Depth mask is a trade-off | `35B52835_colmap_dmask` vs `35B52835_colmap` | Visual: cleaner, more correct opacity, loses the thinnest cables |
| Blur filtering is marginal | `FE934DEC_sharp` vs `FE934DEC_moge` | Visual |
| High normal weights erase thin objects | `68DD2EBE_n02` to `_n40`, `_n20g*`, `_d10`, `_d20` | Visual: chair and tripod legs kept at `n02`, `d10`, `d20`; lost from `n05` up |
| The weight-tuning metric was circular | `evalsplats.py` (not kept) | It scored agreement with the prior being tuned |
| Culling deletes real content | Culled PLYs in `5DABB526_after`, `5DABB526_ceil` | Visual; free-space culling found under 1% floaters |
| No seed means no depth loss | Startup probe on a copy of `staging_CEE18488` | LichtFeld log: no camera aligned, depth loss skipped |
| Training erased the ceiling | `FE934DEC_moge`, `FE934DEC_sharp`; `runs/FE934DEC_ceiling_compare.png` | 98% of the ceiling in view of some frame; 18 opaque Gaussians at ceiling height; hazy even from training cameras |
| Sharp views per point are few | `staging_35B52835_colmap` | Median 8 views per point, 5 sharp, 2 stills |
| ARKit poses are good | COLMAP on `35B52835` (`runs/colmap/35B52835`) | Per-image reprojection median 1.6 px, max 3.6 px |
| Splatfacto's camera moves are not pose error | `runs/ns/35B52835_mono/splatfacto/poses_SO3xR3` | Correlation with COLMAP −0.18; none of its 10 largest in COLMAP's worst 30 |
