# Scan4D → Nerfstudio, flame3d

The app exports one superset, **Scan4D**: everything a scan captured. Other tools read other
layouts. This script makes them from a Scan4D export on your own machine, as the lab server's
`scan4d-convert` pipeline does (scan4d-flows):

```bash
pip install numpy scipy pillow
python3 scan4d_convert.py nerfstudio scan4d_Lab_Room_scan4d_....zip -o lab_room.zip
python3 scan4d_convert.py nerfstudio scan4d_Lab_Room_scan4d_....zip -o lab_room/     # a folder
python3 scan4d_convert.py flame3d    scan4d_Lab_Room_scan4d_....zip -o lab_room_flame3d.zip
```

The input is the export's `.zip` (from Share) or its unpacked folder. An older app Nerfstudio
export works too.

## nerfstudio

A dataset Nerfstudio and LichtFeld Studio load as it is:

```bash
ns-train splatfacto --data lab_room/
LichtFeld-Studio --data-path lab_room/
```

`normalize.py` builds it:
- **`transforms.json`** from the export's `cameras/`. Every frame carries its own intrinsics and
  none are global, because Nerfstudio never reads a frame's value for a key set at the top.
- **Each 12 MP still's true focal.** ARKit reports the video's, scaled up. The device is told by
  its focal/width; `--device` names it when that fails.
- **Depth at each image's size** (LichtFeld requires it), resampled nearest-neighbour into each
  still's own geometry. Scans captured before the app's #93 have byte-swapped depth on disk,
  and it is read the right way round.
- **The 360° rig faces' masks** at the face's size.
- **Fillers:** all-zero depth and all-keep masks where a frame has none, since Nerfstudio wants
  them on every frame or none.

The 360° originals (`equirect_stills/`, `equirect_masks/`) are left out, because no trainer reads
them and they dominate the archive; `--keep-equirects` keeps them. Everything else in the
export comes along. The flow's README, `flows/scan4d_normalize/README.md` in scan4d-flows, has
the details and the checks against the app's former Nerfstudio export.

## flame3d

The same dataset, then [../scan4d-to-flame3d](../scan4d-to-flame3d/README.md) writes the bundle
flame3d-core's `polycam` data source reads: the stream frames and stills at one resolution,
LiDAR depth, the coloured mesh as `raw.glb`, and the registration. `--frames`, `--stride` and
`--max-size` are that converter's options. Check a bundle before uploading it with
`python3 ../scan4d-to-flame3d/scan4d_to_flame3d.py --verify lab_room_flame3d.zip`.

## Where the code lives

`normalize.py` is the original here, in the public app repo, beside the flame3d converter. The
lab server's flows (scan4d-flows: `scan4d_normalize/tools/`, `scan4d_flame3d/tools/`) keep
copies, so their images build without reaching into this repo. Change it here, then copy it
there.
