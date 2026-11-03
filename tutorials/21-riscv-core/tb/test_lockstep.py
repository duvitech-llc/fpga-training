import glob
import os
import random
import sys

import cocotb
from cocotb.clock import Clock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "tools"))
import asm  # noqa: E402
import iss  # noqa: E402
from iss import Iss, Memory  # noqa: E402
from lockstep import BusMemory, Coverage, Lockstep, reset  # noqa: E402

RANDOM_PROGRAMS = 300
RANDOM_LIMIT = 300        # instructions from each random program
BODY = 200                # random instructions after the prologue
DATA = 0x1000             # the data area the base registers point into, 4 KiB
TRAPS = iss.TRAP_NAMES + ["ILLEGAL"]

# Small programs that each end in one kind of trap, or prove one is not taken.
STOPS = [
    ("illegal: zero word",        ".word 0x00000000"),
    ("illegal: all ones",         ".word 0xFFFFFFFF"),
    ("illegal: 16-bit c.nop",     ".word 0x00000001"),
    ("illegal: MUL",              ".word 0x02B50533"),
    ("illegal: CSRRS rdcycle",    ".word 0xC0002573"),
    ("illegal: MRET",             ".word 0x30200073"),
    ("illegal: WFI",              ".word 0x10500073"),
    ("illegal: ECALL with rd",    ".word 0x000000F3"),
    ("illegal: FENCE.I",          ".word 0x0000100F"),
    ("illegal: SLLI shamt 32",    ".word 0x02051513"),
    ("illegal: SLL with funct7 0x20",  ".word 0x40B51533"),
    ("illegal: XOR with funct7 0x20",  ".word 0x40B54533"),
    ("illegal: JALR funct3 1",    ".word 0x00001067"),
    ("illegal: branch funct3 2",  ".word 0x00002063"),
    ("illegal: LD (RV64)",        ".word 0x00003003"),
    ("illegal: LWU (RV64)",       ".word 0x00006003"),
    ("illegal: SD (RV64)",        ".word 0x00003023"),
    ("ecall",                     "ecall"),
    ("ebreak",                    "ebreak"),
    ("misaligned lw",             "li a0, 0x102\nlw a1, 0(a0)"),
    ("misaligned lw +1",          "lw a1, 1(zero)"),
    ("misaligned lh",             "lh a1, 3(zero)"),
    ("misaligned lhu",            "lhu a1, 1(zero)"),
    ("misaligned sw",             "li a1, -1\nsw a1, 2(zero)"),
    ("misaligned sh",             "sh a1, 1(zero)"),
    ("misaligned jal",            ".word 0x0020006F"),          # jal x0, +2
    ("misaligned branch",         ".word 0x00000363"),          # beq x0, x0, +6
    ("misaligned jalr",           "li a0, 0x102\njalr a0"),
    ("not taken: misaligned bne", ".word 0x00001363\nebreak"),  # bne x0, x0, +6
    ("jalr clears bit 0",         "la a0, there+1\njalr a0\necall\nthere: ebreak"),
    ("fence ignores its fields",  ".word 0x8335850F\nebreak"),
]

# 32-bit values where sums, compares and shifts change behaviour.
EDGES = [0, 1, 2, 31, 32, 33, 0x7FF, 0x800, 0x7FFFFFFF, 0x80000000, 0x80000001,
         0xFFFFFFFE, 0xFFFFFFFF, 0xFFFFF800, 0x00010000]
IMM_EDGES = [0, 1, -1, 2, 31, 2047, -2048, 0x7F, -0x80]

# x2, x3 and x4 hold addresses in the data area. Nothing in a random body writes them.
BASES = [2, 3, 4]
TARGETS = [0, 1] + list(range(5, 32))


def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())


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


def random_program(rng):
    """A prologue that gives every register a value, then random instructions.

    Nothing keeps the body safe. It branches and jumps anywhere in itself, loops
    forever, writes over its own code, and may trap. Each program is cut off after
    RANDOM_LIMIT instructions. Only x2, x3 and x4 are kept as addresses, so that
    most loads and stores land in the data area instead of trapping.
    """
    words = []
    for reg in BASES:
        words += asm.li_words(reg, DATA + 4 * rng.randrange(1024 - 32), 0)
    for reg in [1] + list(range(5, 32)):
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
            base = rng.choice(BASES) if rng.random() < 0.92 else rs1
            offset = size * rng.randint(-16, 16)
            if rng.random() < 0.04:
                offset += 1                                        # sometimes misaligned
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
            else:                                  # anywhere: usually a trap
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
    """Every program, and every kind of trap. This coverage does not depend on a seed."""
    start_clock(dut)
    rng = random.Random(cocotb.RANDOM_SEED)
    coverage = Coverage()

    runs = [(name, words) for name, words in assemble_all()]
    runs += [(f"stop: {label}", asm.assemble(source)[0]) for label, source in STOPS]

    for label, words in runs:
        await reset(dut)
        checker = Lockstep(dut, Iss(Memory(words)), BusMemory(words), label, rng,
                           coverage=coverage)
        await checker.run(limit=100000)
        if not checker.model.stopped:
            raise AssertionError(f"{label} did not trap")

    missing = coverage.missing()
    assert not missing, f"never ran: {missing}"
    dut._log.info("directed: " + coverage.summary())


@cocotb.test()
async def random_programs(dut):
    """Random programs, compared at every retire, with random memory waits."""
    start_clock(dut)
    rng = random.Random(cocotb.RANDOM_SEED)
    coverage = Coverage()
    trapped = 0

    for number in range(RANDOM_PROGRAMS):
        words = random_program(rng)
        data = random_data(rng)
        model_memory = Memory(words)
        for address, word in data.items():
            model_memory.write(address, 4, word)
        await reset(dut)
        checker = Lockstep(dut, Iss(model_memory), BusMemory(words, data),
                           f"random program {number}", rng, coverage=coverage)
        await checker.run(limit=RANDOM_LIMIT)
        trapped += checker.model.stopped

    # A trap ends its program, so how many of each kind run depends on the seed.
    # directed_programs runs them all, whatever the seed.
    missing = coverage.missing(skip=TRAPS)
    assert not missing, f"never ran: {missing}"
    dut._log.info(f"random, {RANDOM_PROGRAMS} programs, {trapped} ended in a trap: "
                  + coverage.summary(skip=TRAPS))
