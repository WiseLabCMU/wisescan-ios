# scan4d-to-nerfstudio

Mac or laptop side helpers that turn a Scan4D **Nerfstudio** export into what a Gaussian-splat trainer needs. The pipeline, the measured verdicts, and which of these steps are still worth running are in [docs/design/splat-reconstruction.md](../../docs/design/splat-reconstruction.md); read that first. Never modify the pristine `staging_*` export; build variants as copies with hard links for shared files.

| Script | What it does |
| :-- | :-- |
| `meshrender.py` | Renders per-frame normal maps and depth from the ARKit mesh; writes the seed point cloud (`--seed`) the trainer needs; `--normals skip` ray-casts only frames without LiDAR. |
| `fillholes.py` | Repairs the ARKit mesh before rendering priors: debiases the iso-surface offset and fills planar holes. |
| `pngio.py` | Stdlib-only 16-bit depth and 8-bit confidence PNG read/write, so the tools run on a bare `python3`. |
| `prototypes/colmap_refine.py` | COLMAP features, pose-neighbour matching and triangulation with ARKit poses fixed. |
| `prototypes/refine_perimage.py` | Per-frame drift-free pose refit against the COLMAP points. |
| `prototypes/depth_normal_mask.py` | Depth-consistency mask: drops confidence-0 depth and depth whose LiDAR normal disagrees with the monocular normal. |

Companion tools: [`ar-capture-splat/`](../ar-capture-splat/README.md) (focus capture to a box-cropped reconstruction) and [`scan4d-to-flame3d/`](../scan4d-to-flame3d/README.md) (the Flame3D bundle contract).
