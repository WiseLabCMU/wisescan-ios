"""Minimal stdlib PNG read/write for the 16-bit depth and 8-bit confidence maps.

The bundles only ever contain non-interlaced 8/16-bit greyscale or truecolour PNGs
written by ImageIO, so this covers the five filter types and nothing else. Keeping it
stdlib-only means the converter runs on a bare `python3` with no venv — the whole point
of a tool people reach for once, on a laptop, against a bundle they just AirDropped.
"""

from __future__ import annotations

import struct
import zlib
from pathlib import Path

PNG_SIG = b"\x89PNG\r\n\x1a\n"
_CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}


class PngImage:
    __slots__ = ("width", "height", "bitdepth", "colortype", "channels", "rows")

    def __init__(self, width, height, bitdepth, colortype, channels, rows):
        self.width = width
        self.height = height
        self.bitdepth = bitdepth
        self.colortype = colortype
        self.channels = channels
        self.rows = rows  # list[bytes], unfiltered, PNG byte order (big-endian samples)

    @property
    def stride(self) -> int:
        return (self.width * self.channels * self.bitdepth + 7) // 8

    def samples16(self):
        """Rows as tuples of 16-bit ints, interpreting bytes big-endian per the spec."""
        n = self.width * self.channels
        return [struct.unpack(f">{n}H", row) for row in self.rows]

    def first_channel8(self):
        """Rows as bytes of channel 0, for 8-bit images (drops the duplicated RGB channels)."""
        step = self.channels
        return [bytes(row[0::step]) for row in self.rows] if step > 1 else list(self.rows)


def _unfilter(raw: bytes, height: int, bpp: int, stride: int) -> list:
    rows = []
    prev = bytearray(stride)
    pos = 0
    for y in range(height):
        ftype = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + stride])
        pos += stride
        if len(line) != stride:
            raise ValueError(f"truncated PNG at row {y}")
        if ftype == 0:
            pass
        elif ftype == 1:  # Sub
            for x in range(bpp, stride):
                line[x] = (line[x] + line[x - bpp]) & 0xFF
        elif ftype == 2:  # Up
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 0xFF
        elif ftype == 3:  # Average
            for x in range(stride):
                a = line[x - bpp] if x >= bpp else 0
                line[x] = (line[x] + ((a + prev[x]) >> 1)) & 0xFF
        elif ftype == 4:  # Paeth
            for x in range(stride):
                a = line[x - bpp] if x >= bpp else 0
                b = prev[x]
                c = prev[x - bpp] if x >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pred) & 0xFF
        else:
            raise ValueError(f"unsupported PNG filter type {ftype}")
        rows.append(bytes(line))
        prev = line
    return rows


def read_png(path: Path) -> PngImage:
    data = Path(path).read_bytes()
    if data[:8] != PNG_SIG:
        raise ValueError(f"{path}: not a PNG")
    header = None
    idat = bytearray()
    pos = 8
    while pos + 8 <= len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        ctype = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if ctype == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif ctype == b"IDAT":
            idat += body
        elif ctype == b"IEND":
            break
        pos += 12 + length
    if header is None:
        raise ValueError(f"{path}: missing IHDR")
    width, height, bitdepth, colortype, _comp, _filt, interlace = header
    if interlace:
        raise ValueError(f"{path}: interlaced PNGs are not supported")
    if bitdepth not in (8, 16) or colortype not in _CHANNELS:
        raise ValueError(f"{path}: unsupported bitdepth/colortype {bitdepth}/{colortype}")
    channels = _CHANNELS[colortype]
    bpp = max(1, channels * bitdepth // 8)
    stride = (width * channels * bitdepth + 7) // 8
    rows = _unfilter(zlib.decompress(bytes(idat)), height, bpp, stride)
    return PngImage(width, height, bitdepth, colortype, channels, rows)


def _chunk(ctype: bytes, body: bytes) -> bytes:
    return (struct.pack(">I", len(body)) + ctype + body
            + struct.pack(">I", zlib.crc32(ctype + body) & 0xFFFFFFFF))


def write_png16_gray(path: Path, width: int, height: int, rows) -> None:
    """Write 16-bit greyscale. `rows` are raw big-endian sample bytes, one bytes-like per row."""
    raw = bytearray()
    for row in rows:
        raw.append(0)  # filter type None
        raw += row
    body = (PNG_SIG
            + _chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 16, 0, 0, 0, 0))
            + _chunk(b"IDAT", zlib.compress(bytes(raw), 6))
            + _chunk(b"IEND", b""))
    Path(path).write_bytes(body)


def write_png8_gray(path: Path, width: int, height: int, rows) -> None:
    """Write 8-bit greyscale. `rows` are raw sample bytes, one bytes-like per row."""
    raw = bytearray()
    for row in rows:
        raw.append(0)  # filter type None
        raw += row
    body = (PNG_SIG
            + _chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
            + _chunk(b"IDAT", zlib.compress(bytes(raw), 6))
            + _chunk(b"IEND", b""))
    Path(path).write_bytes(body)


def write_png8_rgb(path: Path, width: int, height: int, rows) -> None:
    """Write 8-bit RGB (colour type 2). `rows` are raw interleaved RGB bytes, one bytes-like per row."""
    raw = bytearray()
    for row in rows:
        raw.append(0)  # filter type None
        raw += row
    body = (PNG_SIG
            + _chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + _chunk(b"IDAT", zlib.compress(bytes(raw), 6))
            + _chunk(b"IEND", b""))
    Path(path).write_bytes(body)


def upscale_nearest8(rows, src_w: int, src_h: int, dst_w: int, dst_h: int) -> list:
    """Nearest-neighbour resample of 8-bit single-channel rows.

    Nearest, not bilinear: these are binary keep/ignore masks, and interpolation would
    invent intermediate values along every boundary. On an integer ratio it is exact.
    """
    x_map = [x * src_w // dst_w for x in range(dst_w)]
    out = []
    for y in range(dst_h):
        src = rows[y * src_h // dst_h]
        out.append(bytes(src[x] for x in x_map))
    return out


def upscale_nearest16(rows, src_w: int, src_h: int, dst_w: int, dst_h: int) -> list:
    """Nearest-neighbour resample of 16-bit single-channel rows, in PNG byte order.

    Nearest is not a shortcut here, it is required: interpolating between two depths
    across an object boundary invents a surface at a range nothing was ever measured at,
    and those "flying pixels" are worse than no depth.

    Each source row is expanded once and reused for every destination row that maps to it
    (a 7.5x upscale reuses each ~7.5 times), which is what keeps this tolerable in pure
    Python — the join-of-slices runs at C speed.
    """
    x_map = [(x * src_w // dst_w) * 2 for x in range(dst_w)]
    cache = {}
    out = []
    for y in range(dst_h):
        sy = y * src_h // dst_h
        wide = cache.get(sy)
        if wide is None:
            src = rows[sy]
            wide = b"".join([src[sx:sx + 2] for sx in x_map])
            cache[sy] = wide
        out.append(wide)
    return out


def byteswap16(row: bytes) -> bytes:
    """Swap every 16-bit sample's byte order. Slice assignment keeps this at C speed."""
    out = bytearray(len(row))
    out[0::2] = row[1::2]
    out[1::2] = row[0::2]
    return bytes(out)
