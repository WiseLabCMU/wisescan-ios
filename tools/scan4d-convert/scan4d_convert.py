#!/usr/bin/env python3
"""Make a Nerfstudio dataset or a flame3d-core bundle from a Scan4D export, on your own machine.

    python3 scan4d_convert.py nerfstudio scan4d_Lab_Room_scan4d_....zip -o lab_room.zip
    python3 scan4d_convert.py nerfstudio scan4d_Lab_Room_scan4d_....zip -o lab_room/   # a folder
    python3 scan4d_convert.py flame3d    scan4d_Lab_Room_scan4d_....zip -o lab_room_flame3d.zip

The app exports one superset, Scan4D (or the lab server holds it as the scan's bundle). This does
what the lab server's scan4d-convert pipeline does, without the server:

  nerfstudio  normalize.py builds the dataset: transforms.json from cameras/, the stills' true focal,
              depth and the 360 rig faces' masks at each image's size, and the all-zero depth and
              all-keep mask fillers Nerfstudio's all-or-none rule needs. Nerfstudio and LichtFeld
              Studio load it as it is. The 360 originals (equirect_stills/, equirect_masks/) are left
              out: no trainer reads them, and they dominate the archive (--keep-equirects keeps them).
  flame3d     the same dataset, then ../scan4d-to-flame3d/scan4d_to_flame3d.py writes the bundle
              flame3d-core's `polycam` data source reads.

The input is the export's .zip or its unpacked folder (an older app Nerfstudio export works too).
Needs numpy, scipy and Pillow.
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
NORMALIZE = HERE / "normalize.py"
FLAME3D = HERE.parent / "scan4d-to-flame3d"
NOT_FOR_TRAINING = ("equirect_stills", "equirect_masks")
STORED = {".jpg", ".jpeg", ".png", ".zip", ".glb"}


def export_root(path: Path) -> Path:
    """The export (cameras/ or transforms.json) at or one level under `path`."""
    def is_export(d: Path) -> bool:
        return (d / "cameras").is_dir() or (d / "transforms.json").is_file()
    if is_export(path):
        return path
    found = [d for d in sorted(path.iterdir()) if d.is_dir() and is_export(d)]
    if len(found) != 1:
        sys.exit(f"{path}: {'no' if not found else 'more than one'} Scan4D export here")
    return found[0]


def normalize(source: Path, out: Path, device: str | None) -> None:
    cmd = [sys.executable, str(NORMALIZE), str(source), str(out)]
    if device:
        cmd += ["--device", device]
    subprocess.run(cmd, check=True)


def pack(folder: Path, archive: Path, skip: tuple[str, ...]) -> int:
    """Zips the folder's tree, its entries at the root; JPEG, PNG and the like stored as they are."""
    count = 0
    archive.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive, "w") as zf:
        for path in sorted(p for p in folder.rglob("*") if p.is_file()):
            relative = path.relative_to(folder)
            if relative.parts[0] in skip:
                continue
            stored = path.suffix.lower() in STORED
            zf.write(path, relative.as_posix(), compress_type=zipfile.ZIP_STORED if stored else zipfile.ZIP_DEFLATED)
            count += 1
    return count


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("target", choices=["nerfstudio", "flame3d"])
    ap.add_argument("export", type=Path, help="the Scan4D export: its .zip or unpacked folder")
    ap.add_argument("-o", "--out", type=Path, required=True,
                    help="a .zip, or (nerfstudio) a folder to write the dataset into")
    ap.add_argument("--device", help="the device model when the export's stills don't identify it (normalize.py)")
    ap.add_argument("--keep-equirects", action="store_true", help="nerfstudio: keep the 360 originals")
    ap.add_argument("--frames", choices=["stream+stills", "stream"], default="stream+stills", help="flame3d")
    ap.add_argument("--stride", type=int, default=1, help="flame3d: keep every Nth stream frame")
    ap.add_argument("--max-size", type=int, default=1920, help="flame3d: cap on the long edge")
    a = ap.parse_args(argv)
    if a.target == "flame3d" and a.out.suffix.lower() != ".zip":
        ap.error("flame3d writes a .zip")

    with tempfile.TemporaryDirectory(prefix="scan4d_convert_") as work:
        work = Path(work)
        source = a.export
        if source.is_file() and source.suffix.lower() == ".zip":
            with zipfile.ZipFile(source) as zf:
                zf.extractall(work / "in")
            source = work / "in"
        root = export_root(source)

        if a.target == "nerfstudio" and a.out.suffix.lower() != ".zip":
            normalize(root, a.out, a.device)
            if not a.keep_equirects:
                for name in NOT_FOR_TRAINING:
                    shutil.rmtree(a.out / name, ignore_errors=True)
            print(f"wrote the dataset to {a.out}")
            return 0

        dataset = work / "norm"
        normalize(root, dataset, a.device)
        if a.target == "nerfstudio":
            count = pack(dataset, a.out, () if a.keep_equirects else NOT_FOR_TRAINING)
            print(f"wrote {a.out}: {count} files")
            return 0

        sys.path.insert(0, str(FLAME3D))
        from scan4d_to_flame3d import convert   # noqa: E402 (beside this tool)
        summary = convert(dataset, a.out, frames_mode=a.frames, stride=a.stride, max_size=a.max_size)
        frames = sum(summary["frames_out"].values())
        print(f"wrote {a.out}: {frames} frames at {summary['image_size'][0]}x{summary['image_size'][1]}")
        print(f"check it with: python3 {FLAME3D / 'scan4d_to_flame3d.py'} --verify {a.out}")
        return 0


if __name__ == "__main__":
    sys.exit(main())
