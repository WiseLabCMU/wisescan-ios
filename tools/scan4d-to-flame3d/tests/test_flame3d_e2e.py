"""End-to-end: run flame3d-core's own Polycam loader on the converted synthetic bundle.

flame3d's first pipeline step (``polycam_process``) loads the bundle, moves it into its
Z-up world, ray-casts a depth map per frame from the mesh, and writes COLMAP files. It runs
on the CPU, so it is tested here for real: flame3d's rendered depth must match the
synthetic scene's analytic depth, which only happens when the mesh, the cameras and the
alignment all land where the converter says they do. Removing registration.json must
break that agreement, which shows the test can fail.

Skipped unless FLAME3D_CORE points at a flame3d-core checkout and open3d + OpenCV are
importable. The checkout is only read; data/ and outputs/ go to a temp dir.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import numpy as np
import pytest

import scan4d_to_flame3d as conv
import synth_bundle as synth

FLAME3D = os.environ.get("FLAME3D_CORE")
if not FLAME3D:
    pytest.skip("set FLAME3D_CORE to a flame3d-core checkout", allow_module_level=True)
try:
    import cv2  # noqa: F401
    import open3d  # noqa: F401
except ImportError as exc:      # also a missing system library, e.g. libEGL for open3d
    pytest.skip(f"flame3d's loader needs open3d and OpenCV: {exc}", allow_module_level=True)


@pytest.fixture(scope="module")
def flame3d(tmp_path_factory):
    sys.path.insert(0, FLAME3D)
    import config_io
    from data_processor.vendor_specific.polycam import process_polycam

    root = tmp_path_factory.mktemp("flame3d")
    config_io.PATHS["data"] = root / "data"
    config_io.PATHS["outputs"] = root / "outputs"
    shipped = json.loads((Path(FLAME3D) / "server" / "default_config.json").read_text())

    def run(bundle: Path, name: str) -> Path:
        zip_path = config_io.get_data_path(name) / "input.zip"
        zip_path.parent.mkdir(parents=True)
        conv.convert(bundle, zip_path, check=False)
        process_polycam(name, depth_tolerance=shipped["polycam"]["depth_tolerance"])
        return config_io.get_output_path(name)

    return run


def depth_error_cm(out: Path, stem: str) -> np.ndarray:
    import cv2
    rendered = cv2.imread(str(out / "rendered_images" / f"{stem}.png"), cv2.IMREAD_UNCHANGED)
    truth = synth.truth_depth(stem, rendered.shape[1], rendered.shape[0])
    return np.abs(rendered.astype(np.float64) / 10.0 - truth * 100.0)


def colmap_images(out: Path) -> list[str]:
    lines = [ln for ln in (out / "colmap" / "images.txt").read_text().splitlines()
             if ln and not ln.startswith("#")]
    return [ln.split()[-1] for ln in lines[0::2]]


def test_flame3d_sees_the_scene_where_it_is(flame3d, tmp_path):
    out = flame3d(synth.make_bundle(tmp_path / "bundle"), "synthetic")

    names = colmap_images(out)
    assert len(names) == 18 and names[0] == "frame_00000.jpg"
    cams = [ln.split() for ln in (out / "colmap" / "cameras.txt").read_text().splitlines()
            if ln and not ln.startswith("#")]
    assert {(c[1], c[2], c[3]) for c in cams} == {("PINHOLE", "192", "144")}
    assert (out / "mesh.glb").is_file() and (out / "images").is_dir()

    for name in names:
        err = depth_error_cm(out, Path(name).stem)
        # Within a millimetre almost everywhere; the tail is pixels straddling a depth edge,
        # where flame3d's ray and the analytic one may pick different sides.
        assert np.median(err) < 0.1, name
        assert np.mean(err < 1.0) > 0.97, name

    # Every frame observes some mesh vertices. How many depends on flame3d's
    # polycam.depth_tolerance (shipped: 0.0001, relative), not on the conversion: a vertex
    # only counts when the pixel ray it lands on hits the surface within that fraction of
    # its own depth, which on an oblique wall at this tiny resolution few manage.
    lines = [ln for ln in (out / "colmap" / "images.txt").read_text().splitlines()
             if not ln.startswith("#")]
    assert all(obs.strip() for obs in lines[1::2])


def test_dropping_registration_breaks_it(flame3d, tmp_path):
    bundle = synth.make_bundle(tmp_path / "bundle")
    (bundle / "registration.json").unlink()
    out = flame3d(bundle, "synthetic_unregistered")
    errs = np.concatenate([depth_error_cm(out, Path(n).stem).ravel() for n in colmap_images(out)])
    assert np.median(errs) > 5.0
