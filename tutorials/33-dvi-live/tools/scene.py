#!/usr/bin/env python3
"""What programs/draw.c draws, written again in Python: scene(n) is the picture
the program puts in the framebuffer for its scene n, as rows of RGB332 bytes.

The testbench decodes frames from the DVI wires; tb/check_frames.py compares
each of them with these scenes. The font comes from tools/font.py, as the C
program's does, so a mistake in a glyph would not be caught here.
"""

from font import FIRST, LAST, rows

W, H = 160, 120


def rgb332(r, g, b):
    return (r << 5) | (g << 2) | b


def to_rgb888(p):
    """The display's expansion of a byte to 8 bits a colour, by repeating bits."""
    r, g, b = p >> 5, (p >> 2) & 7, p & 3
    return ((r << 5) | (r << 2) | (r >> 1),
            (g << 5) | (g << 2) | (g >> 1),
            b * 0x55)


BARS = [rgb332(7, 7, 3), rgb332(7, 7, 0), rgb332(0, 7, 3), rgb332(0, 7, 0),
        rgb332(7, 0, 3), rgb332(7, 0, 0), rgb332(0, 0, 3), rgb332(0, 0, 0)]


def bounce(t, m):
    r = t % (2 * m)
    return 2 * m - r if r > m else r


def scene(n):
    fb = [[0] * W for _ in range(H)]

    def rect(x, y, w, h, c):
        for j in range(y, y + h):
            for i in range(x, x + w):
                fb[j][i] = c

    def text(x, y, s, scale, c):
        for ch in s:
            if FIRST <= ord(ch) <= LAST:
                for row, bits in enumerate(rows(ch)):
                    for col in range(5):
                        if bits & (0x10 >> col):
                            rect(x + col * scale, y + row * scale, scale, scale, c)
            x += 6 * scale

    for band in range(4):
        rect(0, band * 30, W, 30, rgb332(0, 0, band))
    for b in range(8):
        rect(b * 20, 0, 20, 10, BARS[b])
    n32 = n & 0xFFFFFFFF
    rect(bounce(n32 * 7 & 0xFFFFFFFF, W - 20), 46 + bounce(n32 * 3 & 0xFFFFFFFF, 50), 20, 20,
         rgb332(7, 3, 0))
    text(2, 14, "DVI LIVE VIEW", 2, rgb332(7, 7, 0))
    text(47, 32, "TUTORIAL 33", 1, rgb332(7, 7, 3))
    text(4, 110, "FRAME %d" % n32, 1, rgb332(7, 7, 3))
    return fb


def scene_rgb(n):
    """Scene n as the screen should show it: rows of (r, g, b) tuples."""
    return [[to_rgb888(p) for p in row] for row in scene(n)]
