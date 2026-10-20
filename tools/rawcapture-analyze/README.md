# Raw-capture dump analysis

Reads a `raw_capture_*.zip` (or its extracted directory) from the app's **Raw Capture
(experiment)** screen and prints what the capture settings actually did. Only the CSVs
and `manifest.json` are read, so the zip is used as-is. numpy only.

```bash
python analyze.py raw_capture_Office_20261020_101500.zip
python analyze.py raw_capture_Office_20261020_101500.zip --old-exposure 0.0333 --budget-px 2
```

The dump format is described in [docs/developer-tools.md](../../docs/developer-tools.md)
("Raw capture dump").

## Sections

- **stills** — count, stills per minute, the photo pipeline's request-to-capture
  latency, the interval between stills, how many gate checks were held for blur, and
  (when spacing was on) why each still fired: `first`, `rotation`, `shift`, `time`,
  `unspaced`.
- **viewpoint change between consecutive stills** — the rotation between each pair
  of stills from the gyro integral (what "stills per degree" currently is), the
  app's own attitude-based figure for comparison, and the image shift the video
  stream saw. This is the number to set the spacing thresholds against.
- **blur** — for each still, the gyro's mean rate over the exposure window times the
  exposure times the focal length in photo pixels: the rotational smear that actually
  happened, scored against the budget. Then the same motion re-evaluated at the old
  shutter (`--old-exposure`, default 1/30 s, which is what uncapped AE chose indoors)
  and against the old fixed gate (`--old-gate`, default 0.5 rad/s), to separate the
  two things the sharpness change did at once: a shorter shutter and a stricter gate.
  Translational smear is not in these numbers; it needs distance to the surface and a
  pose.
- **depth stream** — frame interval, worst gaps, and how many gaps began while a still
  was in flight, which is the question "does the depth stream stall during a photo".
- **imu** — achieved rate per stream from the manifest, and the gyro interval from
  the file.

## Caveats

- A still's `host_ts` is the capture pipeline's timestamp for the image. Whether it
  marks the start or the middle of the exposure is not documented, so the exposure
  window is taken as `[host_ts, host_ts + exposure_s]`; at 1/120 s and 100 Hz gyro that
  is about one sample either way.
- The rotation between stills is the norm of the integrated rate vector, a small-angle
  shortcut that is fine at the few degrees per still this is used for.
