#!/usr/bin/env python3
"""Generate Trap Tower's launcher icon (godot/assets/icon.png).

Preferred source (user picked 20 Nov 2026): the game logo
(assets/icon-logo.png — pixel-font TRAP TOWER, tiny hero jumping over
spikes, orange background, 512x512, delivered via the browser route
because PNG binaries cannot ride the text-only snapshot push). When
that file is present, this script copies it to icon.png verbatim.

Fallback (no logo file yet, e.g. fresh checkout before the binary
lands): the original flat design, drawn pixel by pixel with the
standard library only (no Pillow): orange background, purple ground,
white rounded-top door, small navy runner. Deterministic output.

The PNG itself is a build artifact, NOT committed (the snapshot-push path
is UTF-8 text only). CI runs this script before the Godot import step;
local developers run it once after checkout.

Usage: python3 tools/make_icon.py [--out PATH]
"""

import argparse
import math
import struct
import sys
import zlib
from pathlib import Path

W, H = 512, 512
ORANGE = (232, 135, 30)
PURPLE = (43, 10, 138)
WHITE = (255, 255, 255)
NAVY = (10, 31, 68)


def _png_chunk(kind: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data))
        + kind
        + data
        + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    )


def render() -> bytes:
    rows = []
    for y in range(H):
        row = bytearray()
        for x in range(W):
            px = ORANGE
            if y >= 400:
                px = PURPLE
            # White rounded-top door: rect x206..306, y200..400 + semicircle cap.
            in_door = (206 <= x <= 306 and 200 <= y <= 400) or (
                150 <= y <= 200
                and math.hypot(x - 256, y - 200) <= 50
                and 206 <= x <= 306
            )
            if in_door:
                px = WHITE
            # Navy runner: head ellipse + body rect, standing on the ground.
            if math.hypot((x - 135) / 15.0, (y - 365) / 15.0) <= 1.0:
                px = NAVY
            if 128 <= x <= 142 and 380 <= y < 400:
                px = NAVY
            row += bytes(px)
        rows.append(b"\x00" + bytes(row))
    raw = b"".join(rows)
    ihdr = struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + _png_chunk(b"IHDR", ihdr)
        + _png_chunk(b"IDAT", zlib.compress(raw, level=9))
        + _png_chunk(b"IEND", b"")
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=None)
    args = ap.parse_args()
    out = (
        Path(args.out)
        if args.out
        else Path(__file__).resolve().parent.parent / "godot" / "assets" / "icon.png"
    )
    out.parent.mkdir(parents=True, exist_ok=True)
    logo_icon = out.parent / "icon-logo.png"
    if logo_icon.is_file():
        out.write_bytes(logo_icon.read_bytes())
        print(f"icon written (logo): {out} ({out.stat().st_size} bytes)")
        return 0
    out.write_bytes(render())
    print(f"icon written: {out} ({out.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
