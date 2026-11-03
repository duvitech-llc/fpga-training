"""Runs programs on the whole system in lockstep with the reference model, with the
cache in the loop and every slave stalling at random.

The model has no cache, so this tests that the cache cannot be seen: every
instruction the core runs, from RAM or the flash, from a hit or a miss, must be
the one the model runs from memory, with the same results. The one exception
is a word stored to since the last invalidate, after its line may have been
fetched; lockstep.py stops a program there.

The cache in tb/cache_top.v is 8 lines of 4 words, 128 bytes, so the programs
here are all bigger than it.
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
import iss  # noqa: E402
from lockstep import Coverage, Lockstep  # noqa: E402
from soc_model import RAM_BYTES, XIP, SocIss, SocMemory  # noqa: E402

LINE_WORDS = 4

RANDOM_FROM_RAM = 120
RANDOM_FROM_FLASH = 40
RANDOM_LIMIT = 300        # instructions from each random program
BODY = 200                # random instructions after the prologue
ORIGIN = 0x100            # where a random program sits, in RAM and in the flash
DATA = 0x1000             # the data area the base registers point into, 4 KiB
TRAPS = iss.TRAP_NAMES + ["ILLEGAL"]


def words_to_bytes(words):
    return b"".join((word & 0xFFFFFFFF).to_bytes(4, "little") for word in words)


def assemble(source):
    return words_to_bytes(asm.assemble(source)[0])


def program(name):
    """A program from programs/, or one that make generated in build/."""
    for folder in (os.path.join(HERE, "..", "programs"), BUILD):
        path = os.path.join(folder, f"{name}.asm")
        if os.path.exists(path):
            with open(path) as file:
                return file.read()
    raise FileNotFoundError(name)


JUMP_TO_FLASH = assemble(program("jump_to_flash"))


def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())


class Board:
    """RAM and flash contents, written through the simulator. Only bytes that
    differ from the last image are written, since each write is slow."""

    def __init__(self, dut):
        self.dut = dut
        self.ram = None
        self.flash = None

    def load(self, ram, flash):
        ram = bytes(ram) + bytes(RAM_BYTES - len(ram))
        flash = bytes(flash) + b"\xFF" * (0x1_0000 - len(flash))
        mem = self.dut.u_soc.u_ram.mem
        for index in range(RAM_BYTES // 4):
            word = ram[4 * index: 4 * index + 4]
            if self.ram is None or word != self.ram[4 * index: 4 * index + 4]:
                mem[index].value = int.from_bytes(word, "little")
        fmem = self.dut.u_flash.mem
        for address in range(len(flash)):
            if self.flash is None or flash[address] != self.flash[address]:
                fmem[address].value = flash[address]
        self.ram, self.flash = ram, flash


async def reset_and_load(dut, board, ram, flash):
    """Holds reset for two clocks, and loads the memories while it is held."""
    await FallingEdge(dut.clk)
    dut.rst.value = 1
    dut.hold.value = 0
    dut.ram_wait.value = 0
    board.load(ram, flash)
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst.value = 0


async def finish(dut):
    """One more clock after the last write to an input. Earlier tutorials saw
    cocotb crash at shutdown without it."""
    await FallingEdge(dut.clk)
    dut.hold.value = 0
    await FallingEdge(dut.clk)


class Totals:
    def __init__(self):
        self.coverage = Coverage()
        self.hits = 0
        self.misses = 0
        self.stalls = 0
        self.fetched_from = set()
        self.stale_stops = []

    def add(self, checker):
        self.hits += checker.hits
        self.misses += checker.misses
        self.stalls += checker.stalls
        self.fetched_from |= checker.fetched_from
        if checker.stale_stop is not None:
            self.stale_stops.append((checker.label, checker.stale_stop))

    def summary(self):
        rate = 100.0 * self.hits / max(1, self.hits + self.misses)
        return (f"{self.coverage.total()} instructions in lockstep, {self.hits} hits, "
                f"{self.misses} misses ({rate:.1f}% hits), {self.stalls} stalled requests, "
                f"fetched from {', '.join(sorted(self.fetched_from))}")


async def run_one(dut, board, ram, flash, label, rng, totals, limit=100000):
    await reset_and_load(dut, board, ram, flash)
    model = SocIss(SocMemory(ram=ram, flash=flash), pc=0)
    checker = Lockstep(dut, model, label, rng, LINE_WORDS, coverage=totals.coverage)
    await checker.run(limit=limit)
    totals.add(checker)
    return checker


# Small programs for the paths a cache must leave alone.
STOPS = [
    ("fetch from a hole", "li t0, 0x30000000\njr t0", 1),
    ("store to the flash", "li t0, 0x40000000\nsw zero, 0(t0)", 7),
    ("fetch from GPIO, not cached",
     "li t0, 0x10001000\nli t1, 0x00100073\nsw t1, 0(t0)\njr t0", 3),
    ("load from the flash, not cached",
     "li t0, 0x40000000\nlw t1, 0(t0)\nlw t2, 8(t0)\nebreak", 3),
]


@cocotb.test()
async def directed_programs(dut):
    """Every program from programs/, from RAM and from the flash, and the paths
    that pass straight through."""
    start_clock(dut)
    rng = random.Random(cocotb.RANDOM_SEED)
    board = Board(dut)
    totals = Totals()

    # selfmod.asm without its second call, which is the one that runs stale code.
    fixed = program("selfmod").replace("jalr   s1                       # 2:", "nop  # 2:")
    runs = [(name, assemble(program(name))) for name in ("tight", "straight", "bigloop", "selfmod")]
    runs.append(("selfmod without call 2", assemble(fixed)))

    for name, image in runs:
        for where in ("RAM", "flash"):
            ram = image if where == "RAM" else JUMP_TO_FLASH
            checker = await run_one(dut, board, ram, image, f"{name} from {where}", rng, totals)
            if name == "selfmod":
                # Stopped at the stale call, as selfmod.asm's comment says.
                if checker.stale_stop != 0x80C0:
                    raise AssertionError(f"{name} from {where}: not stopped at the call of "
                                         f"0x80C0, but {checker.stale_stop}")
            elif checker.trapped is None or checker.trapped.trap != 3:
                raise AssertionError(f"{name} from {where} did not end in ebreak")

    for label, source, cause in STOPS:
        checker = await run_one(dut, board, assemble(source), b"", f"stop: {label}", rng, totals)
        if checker.trapped is None or checker.trapped.trap != cause:
            raise AssertionError(f"{label}: did not stop with cause {cause}")

    await finish(dut)
    assert totals.hits and totals.misses, "no hits or no misses"
    assert totals.fetched_from == {"ram", "xip"}, "not every cacheable region was fetched from"
    dut._log.info("stopped where code was stale: "
                  + ", ".join(f"{label} at {pc:08x}" for label, pc in totals.stale_stops))
    dut._log.info("directed: " + totals.summary())


# ----- Random programs, as in Tutorial 21, laid out for this system -----

# 32-bit values where sums, compares and shifts change behaviour.
EDGES = [0, 1, 2, 31, 32, 33, 0x7FF, 0x800, 0x7FFFFFFF, 0x80000000, 0x80000001,
         0xFFFFFFFE, 0xFFFFFFFF, 0xFFFFF800, 0x00010000]
IMM_EDGES = [0, 1, -1, 2, 31, 2047, -2048, 0x7F, -0x80]

# x2, x3 and x4 hold addresses in the data area, and x5 the start of the flash.
# Nothing in a random body writes them.
BASES = [2, 3, 4]
FLASH_REG = 5
TARGETS = [0, 1] + list(range(6, 32))


def random_value(rng):
    return rng.choice(EDGES) if rng.random() < 0.5 else rng.getrandbits(32)


def random_imm(rng):
    return rng.choice(IMM_EDGES) if rng.random() < 0.4 else rng.randint(-2048, 2047)


def random_program(rng):
    """Tutorial 21's random program, at ORIGIN, with these changes. Stores always
    use a base register, so they land in the data area and never in code: a
    program that writes its own code needs an invalidate, which a random program
    does not know to do. A jalr to an absolute address goes to the copy in RAM or
    the copy in the flash, so one program runs from both, and their lines meet in
    the cache with the same index and different tags."""
    words = []
    for reg in BASES:
        words += asm.li_words(reg, DATA + 4 * rng.randrange(1024 - 32), 0)
    words += asm.li_words(FLASH_REG, XIP, 0)
    for reg in [1] + list(range(6, 32)):
        words += asm.li_words(reg, random_value(rng), 0)
    first = ORIGIN // 4
    start = first + len(words)
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
            base = rng.choice(BASES) if (store or rng.random() < 0.92) else rs1
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
            offset = 4 * rng.randrange(start, end) + rng.choice([0, 0, 0, 1])
            if choice < 0.4:                       # into the copy in RAM
                base = 0
            elif choice < 0.65:                    # into the copy in the flash
                base = FLASH_REG
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

    image = bytearray(DATA + 4096)
    image[ORIGIN: ORIGIN + 4 * len(words)] = words_to_bytes(words)
    for n in range(1024):
        image[DATA + 4 * n: DATA + 4 * n + 4] = random_value(rng).to_bytes(4, "little")
    return image


def entry(image, where):
    """The first words: a jump to ORIGIN in RAM, or in the flash."""
    if where == "RAM":
        words = [asm.j_type(ORIGIN, 0, asm.OP_JAL)]
    else:
        words = [asm.u_type(XIP >> 12, FLASH_REG, asm.OP_LUI),
                 asm.i_type(ORIGIN, FLASH_REG, 0, 0, asm.OP_JALR)]
    image = bytearray(image)
    image[0: 4 * len(words)] = words_to_bytes(words)
    return bytes(image)


@cocotb.test()
async def random_programs(dut):
    """Random programs, started in RAM or in the flash, compared at every retire."""
    start_clock(dut)
    rng = random.Random(cocotb.RANDOM_SEED)
    board = Board(dut)
    totals = Totals()
    trapped = 0

    plan = ["RAM"] * RANDOM_FROM_RAM + ["flash"] * RANDOM_FROM_FLASH
    for number, where in enumerate(plan):
        image = entry(random_program(rng), where)
        checker = await run_one(dut, board, image, image, f"random program {number}, from {where}",
                                rng, totals, limit=RANDOM_LIMIT)
        trapped += checker.trapped is not None

    await finish(dut)
    # A trap ends its program, so how many of each kind run depends on the seed.
    missing = totals.coverage.missing([n for n in iss.all_classes() if n not in TRAPS])
    assert not missing, f"never ran: {missing}"
    assert totals.fetched_from == {"ram", "xip"}, "not every cacheable region was fetched from"
    dut._log.info(f"random: {len(plan)} programs, {RANDOM_FROM_FLASH} started in the flash, "
                  f"{trapped} ended in a trap, {len(totals.stale_stops)} stopped at stale code")
    dut._log.info("random: " + totals.summary())
