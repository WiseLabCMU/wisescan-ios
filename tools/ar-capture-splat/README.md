# ar-capture-splat

One-shot conversion of an **AR Capture** dump into a box-cropped Gaussian splat (LichtFeld Studio).
About 20 to 25 minutes for ~90 stills on an RTX 5080, most of it training.

```
docker build -t scan4d-splat-sfm tools/ar-capture-splat        # once
tools/ar-capture-splat/run.sh <dump dir> [<output dir>] [--full-res] [--pairs rule|topkN] [--iter N]
```

Output: `<output>/train/splat.sog` (cropped to the box), `splat.ply`, `summary.json`, plus
`<output>/work/masks_preview.jpg` and `timings.txt`.

## Stages

| Stage | Runs in | What it does |
|---|---|---|
| `ingest.py` | SfM image, CPU | Copies the stills; writes ARKit's poses in the dataset frame as COLMAP priors and the focus box, if the dump has one |
| `sfm.py` | SfM image, GPU + CPU | SIFT (3200 px, 16k features), matching on pairs chosen from ARKit's poses, `pose_prior_mapper` with ARKit's camera centres as 3 cm priors and intrinsics fixed at the device's still focal |
| MoGe normals | LichtFeld container, GPU | `LichtFeld-Studio preprocess --mode normals`, in parallel with `sfm.py` |
| `box_masks.py` | SfM image, CPU | Per-still masks of pixels whose LiDAR surface lies inside the box, depth resampled into the still grid (0.1 mm units) and zeroed outside, normals blanked outside, seed cropped to the box |
| training | LichtFeld container, GPU | `ssi-depth` depth loss, normal loss, `--mask-mode ignore`, crop box locked by `box_hook.py`; half resolution by default |
| `finalize.py` | both | Hard crop to the box, SOG, `summary.json` |

## Inputs and assumptions

- **The box** comes from the dump's focus region (`manifest.json` `regionToWorld` + `focusRegion.size_m`).
  Without one, `box_masks.py` fits a box to the LiDAR: level with gravity, yawed to the walls, a wall
  face where one is found on each side, else the 2nd/98th percentile, floor to ceiling.
- **Still focal.** ARKit reports a high-resolution still with the video's intrinsics. The true still
  focal is a per-device constant in `ingest.py` (`DEVICE_FOCAL`: M1 iPad Pro 1.0476, iPhone 17 Pro
  Max 1.0136). An unknown device is solved per scan with the focal free; add the result to the table.
- **Poses** stay in ARKit's frame and scale (the centres are priors), so the box needs only the
  dataset's fixed shift and flip.
- **Half resolution** trains about 2.7 times faster than full resolution and scored the same on the
  Focus 3 capture, at full-resolution held-out renders as well. `--full-res` is there for comparison.

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `WISELAB_ROOT` | `/d/Workspace/WiseLab` | Host folder the LichtFeld container mounts at `/workspace`; input and output must sit under it |
| `WISELAB_MOUNT` | `D:/Workspace/WiseLab` | The same folder in `docker run -v` form |
| `LFS_CONTAINER` | `lichtfeld-studio` | Running LichtFeld Studio compose container |
| `LFS_BIN` | `/home/wsl/projects/LichtFeld-Studio/build/LichtFeld-Studio` | LichtFeld binary inside it |
| `LFS_HOME` | `/workspace/4dscans/.lfs_home` | HOME for LichtFeld: MoGe weights cache and the numpy the hook needs (both fetched on first use) |

The SfM image builds on the local `nerfstudio:blackwell` image for its CUDA 12.8 COLMAP 3.11.

## Known limits

- People in the stills bake in as floaters; no person masking yet.
- Stills without LiDAR get masks from the fused LiDAR of the others (speckle where it is sparse).
- The crop-box freeze refreshes only when Gaussians are added or removed, so about 1% of opacity
  leaks past the box; the final hard crop removes it.
