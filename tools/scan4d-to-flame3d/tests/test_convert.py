"""Converter tests against the synthetic bundle (numpy + Pillow + pytest only)."""

from __future__ import annotations

import io
import json
import shutil
import zipfile
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

import scan4d_to_flame3d as conv
import synth_bundle as synth


@pytest.fixture(scope="module")
def bundle(tmp_path_factory):
    return synth.make_bundle(tmp_path_factory.mktemp("bundle"))


@pytest.fixture(scope="module")
def converted(bundle, tmp_path_factory):
    out = tmp_path_factory.mktemp("out") / "f3d.zip"
    summary = conv.convert(bundle, out)
    return zipfile.ZipFile(out), summary


def stems(zf: zipfile.ZipFile, folder: str) -> list[str]:
    return sorted(n.rsplit("/", 1)[1].rsplit(".", 1)[0]
                  for n in zf.namelist() if n.startswith(f"keyframes/{folder}/"))




def test_frame_selection(converted):
    zf, summary = converted
    imgs = stems(zf, "images")
    # 19 sequence frames: 16 stream, stills at 5 and 11, the 16:9 still at 14 dropped;
    # both cube faces dropped.
    assert len(imgs) == 18
    assert "frame_00014" not in imgs and not any(s.startswith("still_") for s in imgs)
    assert imgs == stems(zf, "corrected_cameras") == stems(zf, "depth")
    assert summary["frames_out"] == {"stream": 16, "still": 2}
    assert summary["frames_dropped"] == {"still (aspect differs from the stream)": 1,
                                         "face (excluded)": 2}


def test_one_resolution_and_scaled_intrinsics(converted, bundle):
    zf, _ = converted
    src = {f["file_path"]: f for f in json.loads((bundle / "transforms.json").read_text())["frames"]}
    for stem in stems(zf, "images"):
        cam = json.loads(zf.read(f"keyframes/corrected_cameras/{stem}.json"))
        img = Image.open(io.BytesIO(zf.read(f"keyframes/images/{stem}.jpg")))
        assert img.size == (cam["width"], cam["height"]) == (192, 144)
        s = src[f"images/{stem}.jpg"]
        scale = 192 / s["w"]                    # 0.5 for the stills, 1 for the stream
        assert cam["fx"] == pytest.approx(s["fl_x"] * scale)
        assert cam["cx"] == pytest.approx(s["cx"] * scale)
        assert cam["cy"] == pytest.approx(s["cy"] * scale)
        # The pose is passed through untouched, row-major.
        m = np.array(s["transform_matrix"])
        assert [cam[f"t_{r}{c}"] for r in range(3) for c in range(4)] == \
            pytest.approx(m[:3].reshape(-1).tolist())


def test_alignment_is_registration_verbatim(converted, bundle):
    zf, summary = converted
    info = json.loads(zf.read("mesh_info.json"))
    reg = json.loads((bundle / "registration.json").read_text())
    assert info["alignmentTransform"] == pytest.approx(reg["transform"])
    assert summary["registration"]["applied"] is True
    assert json.loads(zf.read("scan4d/registration.json")) == reg


def test_glb_matches_obj(converted, bundle):
    zf, _ = converted
    glb = conv.read_glb(zf.read("raw.glb"))
    ov, ot, _ = conv.load_obj(bundle / "mesh.obj")
    assert np.allclose(glb["POSITION"], ov.astype(np.float32))
    assert np.array_equal(glb["indices"], ot)


def linear_to_srgb(c: np.ndarray) -> np.ndarray:
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1 / 2.4) - 0.055)


def colorize(bundle) -> "conv.CaptureColors":
    """CaptureColors fed the synthetic frames exactly as the converter feeds it."""
    frames = conv.load_frames(bundle)
    size = conv.output_size(frames, 1920)
    frames, _ = conv.select_frames(frames, "stream+stills", 1, size)
    alignment, _ = conv.load_registration(bundle)
    verts, tris, _ = conv.load_obj(bundle / "mesh.obj")
    cc = conv.CaptureColors(verts, tris, alignment)
    lidar = conv.lidar_sizes(frames, size)
    for f in frames:
        rgb = np.asarray(Image.open(io.BytesIO(conv.convert_image(f, *size))).convert("RGB"))
        depth = conv.read_png(f.depth).astype(np.uint16)
        cc.add(conv.camera_json(f, *size), rgb,
               conv.resample_nearest(depth, *lidar[f.stem]) / 1000.0)
    return cc


def test_vertex_colours_are_the_captured_colours(bundle, converted):
    cc = colorize(bundle)
    seen = cc.obs_w.sum(axis=1) > 0
    srgb, stats = cc.result()
    truth, clear = synth.mesh_truth_rgb()
    err = np.abs(srgb - truth).max(axis=1)
    # Every vertex a frame saw has the scene's real colour (JPEG and nearest-pixel sampling
    # leave a few percent of slack). The cameras never look up, so much of the room is unseen.
    assert seen[clear].mean() > 0.5
    assert np.mean(err[seen & clear] < 0.06) > 0.97
    # Surfaces no frame saw stay grey rather than borrowing a neighbour's colour.
    grey = np.all(srgb == 0.5, axis=1)
    assert stats["unseen_grey"] > 0.1 and np.isclose(grey.mean(), stats["unseen_grey"], atol=1e-3)
    # The GLB carries exactly these colours, linearised as glTF requires.
    zf, summary = converted
    assert summary["mesh"]["colors"] == {"source": "frames", **stats}
    assert np.allclose(conv.read_glb(zf.read("raw.glb"))["COLOR_0"], conv.srgb_to_linear(srgb), atol=1e-6)


def test_person_regions_never_colour_the_mesh(bundle):
    """A person as the export leaves them: pixels pixelated (here: pure magenta) and depth
    zeroed, but at the LiDAR's coarser raster, so the blurred pixels reach one LiDAR pixel
    beyond the zeroed block. No vertex may take a colour from them."""
    frames = conv.load_frames(bundle)
    size = conv.output_size(frames, 1920)
    f = next(fr for fr in frames if fr.stem == "frame_00000")
    alignment, _ = conv.load_registration(bundle)
    verts, tris, _ = conv.load_obj(bundle / "mesh.obj")
    rgb = np.asarray(Image.open(f.image).convert("RGB")).copy()
    rgb[60:120, 60:120] = [255, 0, 255]                     # image pixels
    depth = conv.resample_nearest(conv.read_png(f.depth).astype(np.uint16), 64, 48) / 1000.0
    depth[21:39, 21:39] = 0                                  # LiDAR pixels = image 63..116
    cc = conv.CaptureColors(verts, tris, alignment)
    cc.add(conv.camera_json(f, *size), rgb, depth)
    seen = cc.obs_w.sum(axis=1) > 0
    assert seen.sum() > 100
    got = cc.obs_rgb[seen, 0]
    magenta = (got[:, 0] > 0.6) & (got[:, 1] < 0.25) & (got[:, 2] > 0.6)
    assert not magenta.any()


def test_app_colours_in_mesh_obj_are_used_as_is(bundle, tmp_path):
    coloured = tmp_path / "coloured"
    shutil.copytree(bundle, coloured)
    lines = (coloured / "mesh.obj").read_text().splitlines()
    rng = np.random.default_rng(1)
    rgb = []
    for i, line in enumerate(lines):
        if line.startswith("v "):
            c = rng.random(3)
            rgb.append(c)
            lines[i] = f"{line} {c[0]:.4f} {c[1]:.4f} {c[2]:.4f}"
    (coloured / "mesh.obj").write_text("\n".join(lines) + "\n")
    out = tmp_path / "out.zip"
    summary = conv.convert(coloured, out, check=False)
    assert summary["mesh"]["colors"] == {"source": "mesh.obj"}
    with zipfile.ZipFile(out) as zf:
        got = conv.read_glb(zf.read("raw.glb"))["COLOR_0"]
    assert np.allclose(got, conv.srgb_to_linear(np.round(np.asarray(rgb), 4)), atol=1e-5)


def test_no_colors_writes_geometry_only(bundle, tmp_path):
    out = tmp_path / "plain.zip"
    summary = conv.convert(bundle, out, check=False, colors=False)
    assert summary["mesh"]["colors"] is None
    with zipfile.ZipFile(out) as zf:
        assert "COLOR_0" not in conv.read_glb(zf.read("raw.glb"))


def test_depth_recovers_lidar_raster(converted, bundle):
    zf, _ = converted
    for stem in ("frame_00000", "frame_00005"):           # a stream frame and a still
        depth = np.array(Image.open(io.BytesIO(zf.read(f"keyframes/depth/{stem}.png"))))
        conf = Image.open(bundle / "confidence" / f"{stem}.png")
        assert depth.shape[::-1] == conf.size == (64, 48)
        # The bundle upsampled the raster nearest-neighbour; coming back down must return
        # exactly what the sensor measured: every source pixel is a 3x3 / 6x6 block of it.
        src = np.array(Image.open(bundle / "depth" / f"{stem}.png"))
        k = src.shape[1] // 64
        assert np.array_equal(depth, src[::k, ::k])


def test_check_passes_when_coframed(converted):
    _, summary = converted
    report = summary["check"]
    assert report["agree"] > 0.8
    assert max(report["agree_shifted"].values()) < report["agree"]
    assert report["agree_without_registration"] < 0.2
    assert not any("WARNING" in line for line in conv.describe_check(report))


def test_check_flags_missing_registration(bundle, tmp_path):
    broken = tmp_path / "broken"
    shutil.copytree(bundle, broken)
    (broken / "registration.json").unlink()
    summary = conv.convert(broken, tmp_path / "out.zip")
    assert summary["registration"] is None
    assert any("WARNING" in line for line in conv.describe_check(summary["check"]))


def test_stride_and_stream_only(bundle, tmp_path):
    s = conv.convert(bundle, tmp_path / "a.zip", stride=4, check=False)
    assert s["frames_out"] == {"stream": 4, "still": 2}
    s = conv.convert(bundle, tmp_path / "b.zip", frames_mode="stream", check=False)
    assert s["frames_out"] == {"stream": 16}


def test_zip_input_with_top_folder_and_dir_output(bundle, tmp_path):
    src = tmp_path / "scan4d_export.zip"
    with zipfile.ZipFile(src, "w") as zf:
        for p in bundle.rglob("*"):
            if p.is_file():
                zf.write(p, f"staging_X/{p.relative_to(bundle).as_posix()}")
    out = tmp_path / "unpacked"
    conv.convert(src, out, check=False)
    assert (out / "raw.glb").is_file() and (out / "mesh_info.json").is_file()
    assert len(list((out / "keyframes" / "images").glob("*.jpg"))) == 18


def test_exif_orientation_is_stripped(bundle, tmp_path):
    rotated = tmp_path / "rotated"
    shutil.copytree(bundle, rotated)
    img_path = rotated / "images" / "frame_00000.jpg"
    img = Image.open(img_path)
    exif = Image.Exif()
    exif[0x0112] = 6                                       # "rotate 90 CW to display"
    img.save(img_path, quality=95, exif=exif.tobytes())
    out = tmp_path / "out"
    conv.convert(rotated, out, check=False)
    written = Image.open(out / "keyframes" / "images" / "frame_00000.jpg")
    assert written.size == (192, 144)                      # stored layout kept, not rotated
    assert written.getexif().get(0x0112, 1) == 1


def test_stem_without_frame_number_is_refused(bundle, tmp_path):
    bad = tmp_path / "bad"
    shutil.copytree(bundle, bad)
    meta = json.loads((bad / "transforms.json").read_text())
    (bad / "images" / "frame_00003.jpg").rename(bad / "images" / "frame_three.jpg")
    meta["frames"][3]["file_path"] = "images/frame_three.jpg"
    (bad / "transforms.json").write_text(json.dumps(meta))
    with pytest.raises(SystemExit, match="frame number"):
        conv.convert(bad, tmp_path / "out.zip", check=False)


def test_verify_accepts_converter_output(converted):
    zf, _ = converted
    problems, info = conv.verify_bundle(Path(zf.filename))
    assert problems == []
    assert info["frames"] == 18 and info["image_size"] == [192, 144]
    assert info["vertex_colors"] and info["alignment_applied"]
    assert info["check"]["agree"] > 0.8


def test_verify_rejects_entries_under_a_folder(converted, tmp_path):
    """A directory zip (NSFileCoordinator's) puts the folder itself at the top; flame3d,
    which extracts the upload as-is, would not find keyframes/ there."""
    zf, _ = converted
    nested = tmp_path / "nested.zip"
    with zipfile.ZipFile(nested, "w") as out:
        for name in zf.namelist():
            out.writestr(f"staging_X/{name}", zf.read(name))
    problems, _ = conv.verify_bundle(nested)
    assert problems and "staging_X" in problems[0]


def test_verify_flags_a_missing_depth_map(converted, tmp_path):
    zf, _ = converted
    broken = tmp_path / "broken.zip"
    with zipfile.ZipFile(broken, "w") as out:
        for name in zf.namelist():
            if name != "keyframes/depth/frame_00003.png":
                out.writestr(name, zf.read(name))
    problems, _ = conv.verify_bundle(broken)
    assert any("different frames" in p for p in problems)
