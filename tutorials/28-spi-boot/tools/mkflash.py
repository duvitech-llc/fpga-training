#!/usr/bin/env python3
"""Builds a flash image for the boot ROM: a header, then the payload.

    python3 tools/mkflash.py payload.hex flash.hex [--load 0x1000] [--entry 0x1000]
                             [--pad-to N] [--flip-bit BYTE:BIT] [--magic X] [--length N]

payload.hex is asm.py's output, one 32-bit word per line. Each word goes into
flash little-endian, as the core stores it, so the bytes land in RAM where the
assembler put them.

The header is five little-endian words, as rom/boot.asm reads them:

    +0   magic        0x544F4F42, "BOOT" in ASCII
    +4   length       bytes of payload
    +8   load address
    +12  entry point
    +16  CRC-32       of the payload, from zlib.crc32
    +20  the payload

The output is in the format of Tutorial 24's tb/flash.hex, for $readmemh into
tb/spi_flash_model.v: bytes in hex, 16 to a line. It fills the whole flash,
SIZE bytes, with FF after the image, as an erased NOR flash reads, so
$readmemh fills the whole memory and has nothing to warn about.

The last three options break the image on purpose, after the CRC is worked
out, to test that the boot ROM refuses it:

    --flip-bit 5:3   flips bit 3 of payload byte 5
    --magic X        writes X as the magic word
    --length N       writes N as the length
"""

import argparse
import sys
import zlib

MAGIC = 0x544F4F42
HEADER_BYTES = 20
SIZE = 0x1_0000          # bytes of flash in the testbenches: MEM_BYTES of the model


def read_words(path):
    with open(path) as file:
        return [int(line, 16) for line in file if line.strip()]


def payload_bytes(words, pad_to=0):
    data = b"".join((word & 0xFFFFFFFF).to_bytes(4, "little") for word in words)
    if pad_to:
        if pad_to < len(data):
            raise ValueError(f"the payload is {len(data)} bytes, more than --pad-to {pad_to}")
        data += bytes(pad_to - len(data))
    return data


def build_image(payload, load=0x1000, entry=0x1000, flip_bit=None, magic=MAGIC, length=None):
    """The header and the payload, as bytes. The CRC is of the payload as given;
    the faults are added afterwards."""
    crc = zlib.crc32(payload)
    header = [magic, len(payload) if length is None else length, load, entry, crc]
    image = bytearray(b"".join(word.to_bytes(4, "little") for word in header) + payload)
    if flip_bit is not None:
        byte, bit = flip_bit
        image[HEADER_BYTES + byte] ^= 1 << bit
    return bytes(image), crc


def write_flash(path, image, comment, size=SIZE):
    if len(image) > size:
        raise ValueError(f"the image is {len(image)} bytes, more than the flash's {size}")
    data = image + b"\xFF" * (size - len(image))
    with open(path, "w") as file:
        file.write(f"// {comment}\n")
        for start in range(0, size, 16):
            file.write(" ".join(f"{b:02x}" for b in data[start:start + 16]) + "\n")


def number(text):
    return int(text, 0)


def main():
    parser = argparse.ArgumentParser(description="Build a boot image for SPI flash")
    parser.add_argument("payload", help="asm.py output, one word per line")
    parser.add_argument("output", help="flash image for $readmemh")
    parser.add_argument("--load", type=number, default=0x1000)
    parser.add_argument("--entry", type=number, default=0x1000)
    parser.add_argument("--pad-to", type=number, default=0, help="pad the payload with zeros")
    parser.add_argument("--flip-bit", help="BYTE:BIT of the payload to flip")
    parser.add_argument("--magic", type=number, default=MAGIC)
    parser.add_argument("--length", type=number)
    args = parser.parse_args()

    flip = None
    if args.flip_bit:
        byte, bit = (int(part, 0) for part in args.flip_bit.split(":"))
        flip = (byte, bit)

    try:
        payload = payload_bytes(read_words(args.payload), args.pad_to)
        image, crc = build_image(payload, args.load, args.entry, flip, args.magic, args.length)
        summary = (f"{len(payload)} bytes of payload for {args.load:#010x}, entry "
                   f"{args.entry:#010x}, CRC-32 {crc:08x}")
        faults = []
        if flip:
            faults.append(f"bit {flip[1]} of payload byte {flip[0]} flipped")
        if args.magic != MAGIC:
            faults.append(f"magic {args.magic:08x}")
        if args.length is not None:
            faults.append(f"length {args.length:#x}")
        if faults:
            summary += ", then broken: " + ", ".join(faults)
        write_flash(args.output, image, summary)
    except (OSError, ValueError) as error:
        sys.exit(f"mkflash: {error}")
    print(f"{args.output}: {summary}")


if __name__ == "__main__":
    main()
