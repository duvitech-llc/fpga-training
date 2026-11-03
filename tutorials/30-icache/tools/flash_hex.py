#!/usr/bin/env python3
"""Turns asm.py's output into a flash image, with the program at flash address 0.

    python3 tools/flash_hex.py program.hex flash.hex

Each 32-bit word goes into flash little-endian, as the core reads it, so the
word at flash address 4n is the program's word n. XIP maps flash address 0 to
0x4000_0000.

The output is the format of Tutorial 24's tb/flash.hex, for $readmemh into
tb/spi_flash_model.v: bytes in hex, 16 to a line. The rest of the 64 KiB is FF,
as an erased NOR flash reads, so $readmemh fills the whole memory. There is no
header: unlike Tutorial 28's boot image, nothing is copied, so nothing needs a
length or a CRC.
"""

import sys

SIZE = 0x1_0000          # bytes of flash in the testbenches: MEM_BYTES of the model


def image(words):
    data = b"".join((word & 0xFFFFFFFF).to_bytes(4, "little") for word in words)
    if len(data) > SIZE:
        raise ValueError(f"the program is {len(data)} bytes, more than the flash's {SIZE}")
    return data + b"\xFF" * (SIZE - len(data))


def write(path, data):
    with open(path, "w") as file:
        for start in range(0, len(data), 16):
            file.write(" ".join(f"{b:02x}" for b in data[start:start + 16]) + "\n")


def main():
    source, target = sys.argv[1], sys.argv[2]
    with open(source) as file:
        words = [int(line, 16) for line in file if line.strip()]
    try:
        write(target, image(words))
    except ValueError as error:
        sys.exit(f"flash_hex: {error}")


if __name__ == "__main__":
    main()
