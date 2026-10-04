"""Converter tests against the synthetic bundle (numpy + Pillow + pytest only)."""

from __future__ import annotations

import io
import json
import shutil
import struct
import zipfile

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


def read_glb(data: bytes) -> tuple[np.ndarray, np.ndarray]:
    magic, version, total = struct.unpack_from("<4sII", data, 0)
    assert (magic, version, total) == (b"glTF", 2, len(data))
    jlen, jtype = struct.unpack_from("<I4s", data, 12)
    assert jtype == b"JSON"
    gltf = json.loads(data[20:20 + jlen])
    blen, btype = struct.unpack_from("<I4s", data, 20 + jlen)
    assert btype == b"BIN\0"
    binary = data[28 + jlen:28 + jlen + blen]
    acc = gltf["accessors"]
    views = gltf["bufferViews"]

    def view(i, dtype, cols):
        v = views[acc[i]["bufferView"]]
        arr = np.frombuffer(binary, dtype, acc[i]["count"] * cols, v["byteOffset"])
        return arr.reshape(-1, cols)

    return view(0, "<f4", 3), view(1, "<u4", 1).reshape(-1, 3)


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
    verts, tris = read_glb(zf.read("raw.glb"))
    ov, ot = conv.load_obj(bundle / "mesh.obj")
    assert np.allclose(verts, ov.astype(np.float32))
    assert np.array_equal(tris, ot)


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
