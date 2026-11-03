#!/usr/bin/env python3
"""Pads a .hex file from asm.py with 00000000 words up to a fixed count.

    python3 tools/pad_hex.py in.hex out.hex 16384

$readmemh then fills the whole RAM, so neither simulator warns that the file is
shorter than the memory. 00000000 is not an instruction, so a program that runs
off its end still traps.
"""

import sys


def main():
    source, target, count = sys.argv[1], sys.argv[2], int(sys.argv[3])
    with open(source) as file:
        words = [line.strip() for line in file if line.strip()]
    if len(words) > count:
        sys.exit(f"{source}: {len(words)} words do not fit in {count}")
    words += ["00000000"] * (count - len(words))
    with open(target, "w") as file:
        file.write("\n".join(words) + "\n")


if __name__ == "__main__":
    main()
