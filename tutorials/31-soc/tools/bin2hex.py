#!/usr/bin/env python3
"""Turns a raw binary from objcopy into a .hex file for $readmemh, one 32-bit word
per line, padded with 00000000 words to a fixed count.

    python3 tools/bin2hex.py program.bin program.hex 16384

The binary is the RAM's image from address 0, byte for byte. RISC-V is
little-endian, so the first byte is bits 7 to 0 of the first word. A program too
big for the RAM is an error. The padding does what tools/pad_hex.py does for
asm.py's output: $readmemh fills the whole RAM, and 00000000 is not an
instruction, so a program that runs off its end traps.
"""

import sys


def main():
    source, target, count = sys.argv[1], sys.argv[2], int(sys.argv[3])
    with open(source, "rb") as file:
        data = file.read()
    data += bytes(-len(data) % 4)                  # a whole number of words
    words = [int.from_bytes(data[n:n + 4], "little") for n in range(0, len(data), 4)]
    if len(words) > count:
        sys.exit(f"{source}: {len(words)} words do not fit in {count}")
    words += [0] * (count - len(words))
    with open(target, "w") as file:
        file.write("".join(f"{word:08X}\n" for word in words))


if __name__ == "__main__":
    main()
