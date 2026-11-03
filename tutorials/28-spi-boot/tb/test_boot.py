"""Boots the system from the flash model, in lockstep with the reference model,
with every slave stalling at random.

The boot ROM is make's build/rom_stream_d1.hex or build/rom_poll_d1.hex, written
into the ROM through the simulator. The flash images are built here, with
tools/mkflash.py's build_image, and written into the flash model the same way.
From the first fetch in the ROM to the trap at the end, every instruction is
compared with Tutorial 21's Iss, as in Tutorial 26: the boot ROM, the copy, the
CRC check, and the payload that runs from RAM afterwards.

At the end of each boot the test also checks how it ended: the payload's own
ebreak in RAM, or the boot ROM's halt with a0 just past the message it printed.
"""

import os
import random
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(HERE, "..", "build")
sys.path.insert(0, os.path.join(HERE, "..", "tools"))
import asm  # noqa: E402
import mkflash  # noqa: E402
from lockstep import Coverage, Lockstep  # noqa: E402
from soc_model import ROM, SocIss, SocMemory  # noqa: E402

RAM_END = 0x1_0000
MESSAGES = {"bad magic": "bad_magic", "bad length": "bad_length", "bad CRC": "bad_crc"}
RANDOM_IMAGES = 30


def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())


def read_rom(name):
    """The words of a boot ROM, and its symbols from asm.py's listing."""
    with open(os.path.join(BUILD, f"{name}.hex.raw")) as file:
        words = [int(line, 16) for line in file if line.strip()]
    symbols = {}
    with open(os.path.join(BUILD, f"{name}.lst")) as file:
        for line in file:
            if line.startswith("  ") and " = " in line:
                key, value = line.split(" = ")
                symbols[key.strip()] = int(value, 0)
    return words, symbols


def payload(program):
    with open(os.path.join(HERE, "..", "programs", program)) as file:
        return mkflash.payload_bytes(asm.assemble(file.read())[0])


class Board:
    """The ROM and flash contents, written through the simulator."""

    def __init__(self, dut):
        self.dut = dut
        self.flash_used = 0

    def load_rom(self, words):
        mem = self.dut.u_soc.u_rom.mem
        for index in range(256):
            mem[index].value = words[index] if index < len(words) else 0

    def load_flash(self, image):
        # What the last image left behind is erased, as far as a boot could read.
        data = image + b"\xFF" * max(16, self.flash_used - len(image))
        mem = self.dut.u_flash.mem
        for address, byte in enumerate(data):
            mem[address].value = byte
        self.flash_used = len(image)


async def reset_and_load(dut, board, image):
    """Holds reset for two clocks, and loads the flash while it is held. Inputs
    change on the falling edge."""
    await FallingEdge(dut.clk)
    dut.rst.value = 1
    dut.hold.value = 0
    dut.uart_rx.value = 1
    board.load_flash(image)
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst.value = 0


async def finish(dut):
    """One more clock after the last write to an input. Two earlier tutorials saw
    cocotb crash at shutdown without it."""
    await FallingEdge(dut.clk)
    dut.hold.value = 0
    await FallingEdge(dut.clk)


def expected(load, length, actual_length, magic, flipped):
    """What the boot ROM must do with this header, worked out from boot.asm's
    comment, not from its code."""
    if magic != mkflash.MAGIC:
        return "bad magic"
    if length == 0 or load >= RAM_END or length > RAM_END - load:
        return "bad length"
    if length != actual_length or flipped:
        return "bad CRC"
    return "ok"


async def boot(dut, board, rom, symbols, image, label, rng, coverage, want, trap=3):
    """One boot, in lockstep, then how it ended."""
    await reset_and_load(dut, board, image)
    model = SocIss(SocMemory(rom_words=rom), pc=ROM)
    checker = Lockstep(dut, model, label, rng, coverage=coverage)
    await checker.run(limit=500000)
    if not model.stopped:
        raise AssertionError(f"{label}: did not stop")
    if checker.trapped.trap != trap:
        raise AssertionError(f"{label}: stopped with cause {checker.trapped.trap}, not {trap}")
    if want == "ok":
        if not model.pc < RAM_END:
            raise AssertionError(f"{label}: stopped at {model.pc:08x}, not in RAM")
    else:
        halt = ROM + symbols["halt"]
        message = ROM + symbols[MESSAGES[want]] + len(f"boot: {want}\n")
        if model.pc != halt or model.x[10] != message:
            raise AssertionError(f"{label}: stopped at {model.pc:08x} with a0 {model.x[10]:08x}, "
                                 f"not at the halt, {halt:08x}, with a0 {message:08x} "
                                 f"just past \"boot: {want}\"")
    return checker


@cocotb.test()
async def directed_boots(dut):
    """The good image and each kind of bad one, with both boot ROMs."""
    start_clock(dut)
    rng = random.Random(cocotb.RANDOM_SEED)
    board = Board(dut)
    coverage = Coverage()
    stalls = 0
    by_region = {}
    hello = payload("hello.asm")

    cases = [
        ("hello", mkflash.build_image(hello)[0], "ok", 3),
        ("one bit flipped", mkflash.build_image(hello, flip_bit=(5, 3))[0], "bad CRC", 3),
        ("bad magic", mkflash.build_image(hello, magic=0x544F4F43)[0], "bad magic", 3),
        ("bad length", mkflash.build_image(hello, length=0x10000)[0], "bad length", 3),
        ("boot twice", mkflash.build_image(payload("again.asm"))[0], "ok", 3),
        ("store to the boot ROM", mkflash.build_image(payload("romwrite.asm"))[0], "ok", 7),
    ]
    boots = 0
    for rom_name in ("rom_stream_d1", "rom_poll_d1"):
        rom, symbols = read_rom(rom_name)
        await FallingEdge(dut.clk)
        board.load_rom(rom)
        for label, image, want, trap in cases:
            checker = await boot(dut, board, rom, symbols, image, f"{rom_name}, {label}", rng,
                                 coverage, want, trap)
            boots += 1
            stalls += checker.stalls
            for where, n in checker.data_by_region.items():
                by_region[where] = by_region.get(where, 0) + n

    await finish(dut)
    dut._log.info("loads and stores that finished, by device: "
                  + ", ".join(f"{k} {v}" for k, v in sorted(by_region.items())))
    dut._log.info(f"directed: {boots} boots, {stalls} stalled requests, "
                  f"{coverage.total()} instructions in lockstep")


@cocotb.test()
async def random_images(dut):
    """Images with random padding, load addresses and faults. The test works out
    what the boot ROM must do from the header alone, then checks it did."""
    start_clock(dut)
    rng = random.Random(cocotb.RANDOM_SEED)
    board = Board(dut)
    coverage = Coverage()
    rom, symbols = read_rom("rom_stream_d1")
    await FallingEdge(dut.clk)
    board.load_rom(rom)
    hello = payload("hello.asm")
    outcomes = {}
    stalls = 0

    for number in range(RANDOM_IMAGES):
        data = hello + bytes(rng.getrandbits(8) for _ in range(rng.randrange(0, 200)))
        # The boot ROM does not check that the entry point is a multiple of 4. A
        # jump to one that is not traps with cause 0, so every load is aligned.
        # The last word that fits, the word after it, which does not, and RAM_END.
        last = (RAM_END - len(data)) & ~3
        load = rng.choice([0x1000, 0x4000, 0x8000, last, last + 4, RAM_END])
        fault = rng.choice(["none", "none", "flip", "magic", "length"])
        flip, magic, length = None, mkflash.MAGIC, len(data)
        if fault == "flip":
            flip = (rng.randrange(len(data)), rng.randrange(8))
        elif fault == "magic":
            magic ^= 1 << rng.randrange(32)
        elif fault == "length":
            length = rng.choice([0, len(data) - 1, len(data) + 1, len(data) + 64, 0x10000,
                                 0xFFFFFFFF])
        image, _ = mkflash.build_image(data, load=load, entry=load, flip_bit=flip, magic=magic,
                                       length=length)
        want = expected(load, length, len(data), magic, flip is not None)
        label = f"random image {number}: {fault}, {len(data)} bytes at {load:#x}, want {want}"
        checker = await boot(dut, board, rom, symbols, image, label, rng, coverage, want)
        outcomes[want] = outcomes.get(want, 0) + 1
        stalls += checker.stalls

    await finish(dut)
    for want in ("ok", "bad magic", "bad length", "bad CRC"):
        assert outcomes.get(want, 0) > 0, f"no random image ended in {want}"
    dut._log.info(f"random: {RANDOM_IMAGES} images, "
                  + ", ".join(f"{k} {v}" for k, v in sorted(outcomes.items()))
                  + f", {stalls} stalled requests, {coverage.total()} instructions in lockstep")
