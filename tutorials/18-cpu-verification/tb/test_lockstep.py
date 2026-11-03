import glob
import os
import random
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "tools"))
import asm  # noqa: E402
import iss  # noqa: E402
from iss import Iss  # noqa: E402
from lockstep import Coverage, CpuProbe, load_and_reset, run_lockstep  # noqa: E402

RANDOM_PROGRAMS = 300
RANDOM_LIMIT = 300        # instructions from each random program
TIMEOUT = 20000           # clocks, for the test that does not use lockstep

# Bits each op ignores, which get junk. Spec: "the hardware ignores unused fields".
UNUSED_BITS = {0x0: 0x0F00, 0x1: 0x00F0, 0x2: 0x0300, 0x3: 0x0300, 0x4: 0x0300, 0x5: 0x0300,
               0x8: 0x0F00, 0xA: 0x0F00, 0xB: 0x0FFF, 0xC: 0x0CFF, 0xD: 0x03FF, 0xE: 0x0CFF}

# One word of each illegal kind, and HALT with junk in the fields it ignores.
STOP_WORDS = [0x0002, 0x0FFF, 0x100F, 0x1FFF, 0x9C10, 0x9F00, 0xF000, 0xFFFF, 0x0701]

# Bytes where sums and flags change behaviour. Half of all data is picked from these.
EDGES = [0x00, 0x01, 0x02, 0x7E, 0x7F, 0x80, 0x81, 0xFE, 0xFF]

# Every {z, c, n, v} that can exist. Only 9 of the 16.
REACHABLE = iss.reachable_flags()


def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())


def assemble_all():
    """Every program in programs/, as (name, words)."""
    programs = []
    for path in sorted(glob.glob(os.path.join(HERE, "..", "programs", "*.asm"))):
        with open(path) as file:
            programs.append((os.path.basename(path), asm.assemble(file.read())[0]))
    return programs


def random_byte(rng):
    return rng.choice(EDGES) if rng.random() < 0.5 else rng.randrange(256)


def random_word(rng):
    """Any legal instruction, with any operands. Nothing keeps a program safe: it can
    jump anywhere, use R3 for anything, and run off the end of memory. That was not
    possible in Tutorial 17, where a program had to reach HALT to be checked at all."""
    rd, rs, imm = rng.randrange(4), rng.randrange(4), random_byte(rng)
    kind = rng.random()

    if kind < 0.35:                                # ALU
        word = 0x1000 | rng.randrange(15)
    elif kind < 0.47:                              # LDI
        word = 0x2000 | imm
    elif kind < 0.60:                              # ADDI, CMPI, ANDI
        word = rng.choice([0x3000, 0x4000, 0x5000]) | imm
    elif kind < 0.72:                              # LD, ST
        word = rng.choice([0x6000, 0x7000]) | imm
    elif kind < 0.84:                              # Bcc
        return 0x9000 | (rng.randrange(12) << 8) | rng.randrange(256)
    elif kind < 0.97:                              # JMP, CALL, RET, PUSH, POP, JR
        word = rng.choice([0x8000, 0xA000, 0xB000, 0xC000, 0xD000, 0xE000]) | imm
    elif kind < 0.99:                              # NOP
        word = 0x0000
    elif kind < 0.997:                             # HALT
        word = 0x0001
    else:
        return rng.choice(STOP_WORDS[:-1])

    word |= (rd << 10) | (rs << 8)
    op = word >> 12
    keep = 0xFFFF ^ UNUSED_BITS.get(op, 0)
    junk = rng.randrange(0x10000) if rng.random() < 0.33 else 0
    return (word & keep) | (junk & UNUSED_BITS.get(op, 0))


@cocotb.test()
async def directed_programs(dut):
    """Every program, and every kind of stop. This coverage does not depend on a seed."""
    start_clock(dut)
    coverage = Coverage()

    for name, words in assemble_all():
        await load_and_reset(dut, words)
        await run_lockstep(dut, CpuProbe(dut), Iss(words), name, coverage)

    for stop in STOP_WORDS:
        words = [stop] + [0] * 255
        await load_and_reset(dut, words)
        await run_lockstep(dut, CpuProbe(dut), Iss(words), f"stop word {stop:04X}", coverage)

    missing = coverage.missing(REACHABLE)
    assert not missing, f"never ran: {missing}"
    dut._log.info("directed: " + coverage.summary())


@cocotb.test()
async def random_programs(dut):
    """Wild random programs, compared at every retire."""
    start_clock(dut)
    rng = random.Random(cocotb.RANDOM_SEED)
    coverage = Coverage()

    for number in range(RANDOM_PROGRAMS):
        words = [random_word(rng) for _ in range(256)]
        data = [random_byte(rng) for _ in range(256)]
        await load_and_reset(dut, words, data)
        await run_lockstep(dut, CpuProbe(dut), Iss(words, list(data)),
                           f"random program {number}", coverage, limit=RANDOM_LIMIT)

    # An illegal word ends its program, so each kind is rare here, and whether one runs
    # depends on the seed. directed_programs runs them all, whatever the seed.
    missing = [name for name in coverage.missing(REACHABLE) if name not in iss.ILLEGAL_NAMES]
    assert not missing, f"never ran: {missing}"
    dut._log.info(f"random, {RANDOM_PROGRAMS} programs: " + coverage.summary())
    dut._log.info("flags seen: " + ", ".join(
        f"{''.join(map(str, flags))}:{count}" for flags, count in sorted(coverage.flag_sets.items())))


@cocotb.test()
async def final_state_only(dut):
    """The method of Tutorial 17: run to HALT, then compare once. Kept here to show what
    it cannot see. Only overwrite.asm runs, since other programs would catch the bug
    that this test exists to miss."""
    start_clock(dut)
    words = dict(assemble_all())["overwrite.asm"]

    model = Iss(words)
    while not model.stopped:
        model.step()

    await load_and_reset(dut, words)
    for _ in range(TIMEOUT):
        await FallingEdge(dut.clk)
        if int(dut.halted.value):
            break
    assert int(dut.halted.value), "the CPU did not halt"

    probe = CpuProbe(dut)
    assert probe.registers() == tuple(model.regs), "final registers"
    assert probe.flags() == model.flags(), "final flags"
    assert int(dut.u_cpu.pc.value) == model.pc, "final PC"
    for address in range(256):
        assert int(dut.dmem[address].value) == model.mem[address], "final memory"
