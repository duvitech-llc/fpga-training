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
from lockstep import Coverage, Lockstep, RamLoader  # noqa: E402
from soc_model import FAULT_NAMES, SocIss, SocMemory  # noqa: E402

RANDOM_PROGRAMS = 200
RANDOM_LIMIT = 300        # instructions from each random program
BODY = 200                # random instructions after the prologue
DATA = 0x1000             # the RAM data area the RAM base registers point into, 4 KiB
TRAPS = iss.TRAP_NAMES + FAULT_NAMES

# Small programs that each end in one kind of trap. The access faults are new in
# this lesson. A few of Tutorial 21's traps are kept, to show the core's own traps
# still come out with their own causes.
STOPS = [
    ("load from nothing",          "li a0, 0x30000000\nlw a1, 0(a0)"),
    ("load just past RAM",         "li a0, 0x10000\nlbu a1, 0(a0)"),
    ("store to nothing",           "li a0, 0x30000000\nsw a1, 0(a0)"),
    ("store just past the UART",   "li a0, 0x10000008\nsb a1, 0(a0)"),
    ("load past GPIO",             "li a0, 0x10001004\nlw a1, 0(a0)"),
    ("store to AXI4-Lite ID",      "li a0, 0x20000010\nsw a1, 0(a0)"),
    ("byte store to AXI4-Lite ID", "li a0, 0x20000013\nsb a1, 0(a0)"),
    ("load from AXI4-Lite hole",   "li a0, 0x20000014\nlw a1, 0(a0)"),
    ("store to AXI4-Lite hole",    "li a0, 0x2000001C\nsh a1, 2(a0)"),
    ("jump to nothing",            "li a0, 0x30000000\njr a0"),
    ("jump past RAM",              "li a0, 0x10000\njr a0"),
    ("jump to AXI4-Lite hole",     "li a0, 0x20000018\njr a0"),
    ("misaligned load from nothing", "li a0, 0x30000002\nlw a1, 0(a0)"),
    ("ecall",                      "ecall"),
    ("ebreak",                     "ebreak"),
    ("illegal",                    ".word 0x00000000"),
    ("misaligned sw",              "li a1, -1\nsw a1, 2(zero)"),
    ("misaligned jal",             ".word 0x0020006F"),          # jal x0, +2
    ("misaligned branch",          ".word 0x00000363"),          # beq x0, x0, +6
    ("misaligned jalr",            "li a0, 0x102\njalr a0"),
    ("read ID, then stop",         "li a0, 0x20000010\nlw a1, 0(a0)\nlbu a2, 3(a0)\nebreak"),
    ("GPIO bytes, then stop",      "li a0, 0x10001000\nli a1, -1\nsw a1, 0(a0)\nsb zero, 1(a0)"
                                   "\nlw a2, 0(a0)\nlh a3, 2(a0)\nebreak"),
    ("run code from AXI4-Lite",    "li a0, 0x20000000\nli a1, 0x00100073\nsw a1, 0(a0)\njr a0"),
]

# 32-bit values where sums, compares and shifts change behaviour.
EDGES = [0, 1, 2, 31, 32, 33, 0x7FF, 0x800, 0x7FFFFFFF, 0x80000000, 0x80000001,
         0xFFFFFFFE, 0xFFFFFFFF, 0xFFFFF800, 0x00010000]
IMM_EDGES = [0, 1, -1, 2, 31, 2047, -2048, 0x7F, -0x80]

# x2 and x3 point into RAM, x4 at the AXI4-Lite block and x5 at the GPIO register.
# Nothing in a random body writes them.
RAM_BASES = [2, 3]
AXIL_BASE, GPIO_BASE = 4, 5
TARGETS = [0, 1] + list(range(6, 32))


def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())


async def reset_and_load(dut, loader, words, data=None):
    """Holds reset for two clocks, and loads RAM while it is held. Inputs change on
    the falling edge."""
    await FallingEdge(dut.clk)
    dut.rst.value = 1
    dut.hold.value = 0
    dut.uart_rx.value = 1
    loader.load(words, data)
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst.value = 0


async def finish(dut):
    """One more clock after the last write to an input. Two earlier tutorials saw
    cocotb crash at shutdown without it."""
    await FallingEdge(dut.clk)
    dut.hold.value = 0
    await FallingEdge(dut.clk)


def assemble_all():
    programs = []
    for path in sorted(glob.glob(os.path.join(HERE, "..", "programs", "*.asm"))):
        with open(path) as file:
            programs.append((os.path.basename(path), asm.assemble(file.read())[0]))
    return programs


def random_value(rng):
    return rng.choice(EDGES) if rng.random() < 0.5 else rng.getrandbits(32)


def random_imm(rng):
    return rng.choice(IMM_EDGES) if rng.random() < 0.4 else rng.randint(-2048, 2047)


def random_access(rng, size, rs1):
    """A base register and an offset for a load or store. Mostly RAM, sometimes a
    register on the bus, sometimes a hole that faults or a misaligned address."""
    kind = rng.random()
    if kind < 0.75:
        base, offset = rng.choice(RAM_BASES), size * rng.randint(-16, 16)
    elif kind < 0.87:
        # reg0 to reg3 and ID mostly, the hole from 0x14 up sometimes
        top = 0x14 if rng.random() < 0.85 else 0x20
        base, offset = AXIL_BASE, size * rng.randrange(top // size)
    elif kind < 0.95:
        # the one word, and sometimes the word after it, which nobody owns
        base, offset = GPIO_BASE, size * rng.randrange(4 // size) + (4 if rng.random() < 0.1 else 0)
    else:
        base, offset = rs1, random_imm(rng) // size * size
    if rng.random() < 0.04:
        offset += 1                                                 # sometimes misaligned
    return base, offset


def random_program(rng):
    """Tutorial 21's random programs, with loads and stores spread over the bus.

    A prologue gives every register a value, then random instructions follow.
    Nothing keeps the body safe. It branches and jumps anywhere in itself, loops
    forever, writes over its own code, and may trap or fault. Each program is cut
    off after RANDOM_LIMIT instructions.
    """
    words = []
    for reg in RAM_BASES:
        words += asm.li_words(reg, DATA + 4 * rng.randrange(1024 - 32), 0)
    words += asm.li_words(AXIL_BASE, 0x2000_0000, 0)
    words += asm.li_words(GPIO_BASE, 0x1000_1000, 0)
    for reg in TARGETS[1:]:
        words += asm.li_words(reg, random_value(rng), 0)
    start = len(words)
    end = start + BODY

    def target_offset(here):
        offset = 4 * (rng.randrange(start, end) - here)
        return offset + 2 if rng.random() < 0.03 else offset      # sometimes misaligned

    for here in range(start, end):
        rd = rng.choice(TARGETS) if rng.random() < 0.95 else 0
        rs1, rs2 = rng.randrange(32), rng.randrange(32)
        kind = rng.random()
        if kind < 0.22:
            name = rng.choice(list(asm.REG_ALU))
            funct3, funct7 = asm.REG_ALU[name]
            word = asm.r_type(funct7, rs2, rs1, funct3, rd, asm.OP_REG)
        elif kind < 0.36:
            name = rng.choice(list(asm.IMM_ALU))
            word = asm.i_type(random_imm(rng), rs1, asm.IMM_ALU[name], rd, asm.OP_IMM)
        elif kind < 0.42:
            name = rng.choice(list(asm.SHIFT_IMM))
            funct3, funct7 = asm.SHIFT_IMM[name]
            word = asm.i_type((funct7 << 5) | rng.randrange(32), rs1, funct3, rd, asm.OP_IMM)
        elif kind < 0.46:
            opcode = rng.choice([asm.OP_LUI, asm.OP_AUIPC])
            word = asm.u_type(rng.getrandbits(20), rd, opcode)
        elif kind < 0.68:
            store = rng.random() < 0.45
            table = asm.STORES if store else asm.LOADS
            name = rng.choice(list(table))
            size = {"b": 1, "h": 2, "w": 4}[name[1]]
            base, offset = random_access(rng, size, rs1)
            if store:
                word = asm.s_type(offset, rs2, base, table[name], asm.OP_STORE)
            else:
                word = asm.i_type(offset, base, table[name], rd, asm.OP_LOAD)
        elif kind < 0.86:
            funct3 = rng.choice(list(asm.BRANCHES.values()))
            if rng.random() < 0.3:
                rs2 = rs1                                          # so equal values happen
            word = asm.b_type(target_offset(here), rs2, rs1, funct3, asm.OP_BRANCH)
        elif kind < 0.92:
            word = asm.j_type(target_offset(here), rd, asm.OP_JAL)
        elif kind < 0.98:
            choice = rng.random()
            if choice < 0.6:                       # an absolute address in the body
                base, offset = 0, 4 * rng.randrange(start, end) + rng.choice([0, 0, 0, 1])
            elif choice < 0.85:                    # a return through ra
                base, offset = 1, 0
            else:                                  # anywhere: usually a fault or a trap
                base, offset = rs1, random_imm(rng)
            word = asm.i_type(offset, base, 0, rd, asm.OP_JALR)
        elif kind < 0.995:
            word = 0x0000000F | (rng.getrandbits(17) << 15) | (rng.randrange(32) << 7)
        else:
            word = rng.choice([0x00000073, 0x00100073, 0x00000000, 0x02B50533])
        words.append(word)
    return words


def random_data(rng):
    return {DATA + 4 * n: random_value(rng) for n in range(1024)}


@cocotb.test()
async def directed_programs(dut):
    """Every program in programs/, and every kind of access fault."""
    start_clock(dut)
    rng = random.Random(cocotb.RANDOM_SEED)
    coverage = Coverage()
    loader = RamLoader(dut)
    stalls = 0
    by_region = {}

    runs = [(name, words) for name, words in assemble_all()]
    runs += [(f"stop: {label}", asm.assemble(source)[0]) for label, source in STOPS]

    for label, words in runs:
        await reset_and_load(dut, loader, words)
        checker = Lockstep(dut, SocIss(SocMemory(words)), loader, label, rng,
                           coverage=coverage)
        await checker.run(limit=200000)
        if not checker.model.stopped:
            raise AssertionError(f"{label} did not trap")
        stalls += checker.stalls
        for where, n in checker.data_by_region.items():
            by_region[where] = by_region.get(where, 0) + n

    await finish(dut)
    wanted = TRAPS
    missing = coverage.missing(wanted)
    assert not missing, f"never ran: {missing}"
    dut._log.info("loads and stores that finished, by device: "
                  + ", ".join(f"{k} {v}" for k, v in sorted(by_region.items())))
    dut._log.info(f"directed: {len(runs)} programs, {stalls} stalled requests: "
                  + coverage.summary(wanted))


@cocotb.test()
async def random_programs(dut):
    """Random programs, compared at every retire, with every slave stalling at random."""
    start_clock(dut)
    rng = random.Random(cocotb.RANDOM_SEED)
    coverage = Coverage()
    loader = RamLoader(dut)
    trapped = 0
    faults = 0
    stalls = 0
    by_region = {}

    for number in range(RANDOM_PROGRAMS):
        words = random_program(rng)
        data = random_data(rng)
        model_memory = SocMemory(words, data)
        await reset_and_load(dut, loader, words, data)
        checker = Lockstep(dut, SocIss(model_memory), loader, f"random program {number}", rng,
                           coverage=coverage)
        await checker.run(limit=RANDOM_LIMIT)
        trapped += checker.model.stopped
        faults += int(dut.trap.value) and int(dut.trap_cause.value) in (1, 5, 7)
        stalls += checker.stalls
        for where, n in checker.data_by_region.items():
            by_region[where] = by_region.get(where, 0) + n

    await finish(dut)
    # A trap ends its program, so how many of each kind run depends on the seed.
    # directed_programs runs them all, whatever the seed.
    wanted = [name for name in iss.all_classes() if name not in TRAPS]
    missing = coverage.missing(wanted)
    assert not missing, f"never ran: {missing}"
    dut._log.info("loads and stores that finished, by device: "
                  + ", ".join(f"{k} {v}" for k, v in sorted(by_region.items())))
    dut._log.info(f"random, {RANDOM_PROGRAMS} programs, {trapped} ended in a trap, {faults} of "
                  f"them access faults, {stalls} stalled requests: " + coverage.summary(wanted))
