"""Write PNG files with only the Python standard library.

A PNG file is a signature followed by chunks. Each chunk is a length, a
four-letter type, the data, and a CRC-32 of the type and data. Three chunks are
enough: IHDR says the size and format, IDAT holds the pixels compressed with
zlib, and IEND ends the file.
"""

import struct
import zlib


def _chunk(kind, data):
    body = kind + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))


def write_png(path, rows, scale=1):
    """rows is a list of rows, each a list of (r, g, b) tuples of 0 to 255.

    scale repeats each pixel scale times across and down, so that a tiny frame
    is big enough to look at.
    """
    height = len(rows) * scale
    width = len(rows[0]) * scale
    raw = bytearray()
    for row in rows:
        line = bytearray([0])   # filter type 0: the bytes are stored as they are
        for pixel in row:
            line += bytes(pixel) * scale
        raw += bytes(line) * scale
    # 8 bits per sample, colour type 2 (RGB), default compression, filter and no interlace.
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(_chunk(b"IHDR", header))
        f.write(_chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
        f.write(_chunk(b"IEND", b""))
