#!/usr/bin/env python3
"""Checks the frames that tb_dvi.v decoded from the DVI wires against what
programs/draw.c should have drawn, from tools/scene.py.

    python3 tb/check_frames.py DIR [LIVE]

Reads DIR/frame_NN.png. Each frame must be black, before the program turned the
display on, or exactly scene n for some n. Once the first scene is shown, the
next frames must show the same scene again, or the next one: the program draws
one scene at a time, and the display swaps buffers only at a vertical blank.
At least three different scenes must be seen. If LIVE is given, that file must
hold the same picture as the last numbered frame.

The PNG files are read with the standard library: zlib undoes the stored
blocks, and every row has filter 0.
"""

import glob
import os
import struct
import sys
import zlib

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
from scene import H, W, scene_rgb   # noqa: E402

SCALE = 2


def read_png(path):
    """Rows of (r, g, b) tuples, from a PNG of the kind tb_dvi.v writes."""
    with open(path, "rb") as f:
        data = f.read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", path + ": not a PNG file"
    pos, idat, width, height = 8, b"", 0, 0
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        crc, = struct.unpack(">I", data[pos + 8 + length:pos + 12 + length])
        assert crc == zlib.crc32(kind + body), "%s: bad CRC in %s" % (path, kind)
        if kind == b"IHDR":
            width, height, depth, colour = struct.unpack(">IIBB", body[:10])
            assert depth == 8 and colour == 2, path + ": not 8-bit RGB"
        elif kind == b"IDAT":
            idat += body
        pos += 12 + length
    raw = zlib.decompress(idat)
    stride = 1 + 3 * width
    assert len(raw) == height * stride, path + ": wrong amount of image data"
    rows = []
    for y in range(height):
        line = raw[y * stride:(y + 1) * stride]
        assert line[0] == 0, path + ": a row with a filter"
        rows.append([tuple(line[1 + 3 * x:4 + 3 * x]) for x in range(width)])
    return rows


def shrink(rows):
    """Back to one pixel per frame pixel, checking each SCALE x SCALE block is one colour."""
    assert len(rows) == H * SCALE and len(rows[0]) == W * SCALE, "wrong size"
    out = []
    for y in range(H):
        line = []
        for x in range(W):
            p = rows[y * SCALE][x * SCALE]
            for dy in range(SCALE):
                for dx in range(SCALE):
                    assert rows[y * SCALE + dy][x * SCALE + dx] == p, "a block of two colours"
            line.append(p)
        out.append(line)
    return out


def main():
    directory = sys.argv[1]
    paths = sorted(glob.glob(os.path.join(directory, "frame_*.png")))
    if not paths:
        sys.exit("FAIL: no frames in " + directory)
    black = [[(0, 0, 0)] * W for _ in range(H)]
    cache = {}

    def model(n):
        if n not in cache:
            cache[n] = scene_rgb(n)
        return cache[n]

    last, seen, failed = None, [], False
    for path in paths:
        frame = shrink(read_png(path))
        name = os.path.basename(path)
        if frame == black and last is None:
            print("%s: black" % name)
            continue
        # The first scene shown may be 0, or a later one if the program drew
        # faster than the display took them; after that, the same or the next.
        candidates = range(0, 4) if last is None else (last, last + 1)
        match = next((n for n in candidates if frame == model(n)), None)
        if match is None:
            # Say where the nearest scene differs, to help.
            n = candidates[0] if last is None else last + 1
            want = model(n)
            diffs = [(x, y) for y in range(H) for x in range(W) if frame[y][x] != want[y][x]]
            print("FAIL %s: matches no scene it may show; against scene %d, %d pixels differ, "
                  "the first at (%d, %d)" % (name, n, len(diffs), *diffs[0]))
            failed = True
            break
        print("%s: scene %d, all %d pixels match" % (name, match, W * H))
        last = match
        if match not in seen:
            seen.append(match)

    if not failed and len(seen) < 3:
        print("FAIL: only %d different scenes were shown" % len(seen))
        failed = True

    if not failed and len(sys.argv) > 2:
        live = shrink(read_png(sys.argv[2]))
        if live != shrink(read_png(paths[-1])):
            print("FAIL: %s is not the last frame" % sys.argv[2])
            failed = True
        else:
            print("%s: the same picture as %s" % (sys.argv[2], os.path.basename(paths[-1])))

    if failed:
        sys.exit(1)
    print("frames match the model: scenes %s" % " ".join(str(n) for n in seen))


if __name__ == "__main__":
    main()
