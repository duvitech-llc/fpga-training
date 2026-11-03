import glob
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
from iss import Iss  # noqa: E402
from lockstep import Coverage, Lockstep, RamLoader, UartSender  # noqa: E402
from soc_model import SocMemory  # noqa: E402

CLKS_PER_BIT = int(os.environ.get("CLKS_PER_BIT", "16"))
RANDOM_PROGRAMS = 200
RANDOM_LIMIT = 400        # steps from each random program
BODY = 200                # random instructions after the prologue
DATA = 0x1000             # the RAM data area the RAM base registers point into, 4 KiB
HANDLER = 0x3000          # the random programs' trap handler
TRAPS = iss.TRAP_NAMES

# What each program in programs/ is sent after each ">" it prints.
INPUTS = {"irq": b"x", "echo": b"Hello, interrupts!\n", "pollirq": b"abcdefghijklmnop"}

# Small programs that each take one kind of trap. Each runs after a prologue that
# points mtvec at a handler that is a single ebreak, so the trap is checked, then the
# program stops.
STOPS = [
    ("load from nothing",          "li a0, 0x30000000\nlw a1, 0(a0)"),
    ("load just past RAM",         "li a0, 0x10000\nlbu a1, 0(a0)"),
    ("store to nothing",           "li a0, 0x30000000\nsw a1, 0(a0)"),
    ("store just past the UART",   "li a0, 0x10000008\nsb a1, 0(a0)"),
    ("load just past the timer",   "li a0, 0x10003010\nlw a1, 0(a0)"),
    ("store to AXI4-Lite ID",      "li a0, 0x20000010\nsw a1, 0(a0)"),
    ("load from AXI4-Lite hole",   "li a0, 0x20000014\nlw a1, 0(a0)"),
    ("jump to nothing",            "li a0, 0x30000000\njr a0"),
    ("jump past RAM",              "li a0, 0x10000\njr a0"),
    ("misaligned load from nothing", "li a0, 0x30000002\nlw a1, 0(a0)"),
    ("ecall",                      "ecall"),
    ("ebreak",                     "ebreak"),
    ("illegal: zero",              ".word 0x00000000"),
    ("illegal: WFI",               ".word 0x10500073"),
    ("illegal: CSR funct3 100",    ".word 0x30004073"),
    ("illegal: no such CSR",       "csrr a0, cycle"),
    ("illegal: write mhartid",     "csrw mhartid, a0"),
    ("illegal: csrrwi mvendorid",  "csrrwi zero, mvendorid, 0"),
    ("CSR reads and writes",       "csrr a0, mhartid\ncsrrsi a1, misa, 0\ncsrwi mscratch, 5"
                                   "\ncsrrci a2, mscratch, 1\ncsrrc a3, mscratch, a2"),
    ("misaligned sw",              "li a1, -1\nsw a1, 2(zero)"),
    ("misaligned lh",              "lh a1, 3(zero)"),
    ("misaligned jal",             ".word 0x0020006F"),          # jal x0, +2
    ("misaligned branch",          ".word 0x00000363"),          # beq x0, x0, +6
    ("misaligned jalr",            "li a0, 0x102\njalr a0"),
    ("mret to mepc",               "la a0, there\ncsrw mepc, a0\nmret\necall\nthere: nop"),
    ("WARL bits",                  "li a0, -1\ncsrw mtvec, a0\ncsrw mepc, a0\ncsrw mcause, a0"
                                   "\ncsrw mstatus, a0\ncsrw mie, a0\ncsrw mip, a0\ncsrw misa, a0"
                                   "\ncsrw mstatush, a0\ncsrc mstatus, a0\nla a0, handler"
                                   "\ncsrw mtvec, a0"),
]

# 32-bit values where sums, compares and shifts change behaviour.
EDGES = [0, 1, 2, 31, 32, 33, 0x7FF, 0x800, 0x7FFFFFFF, 0x80000000, 0x80000001,
         0xFFFFFFFE, 0xFFFFFFFF, 0xFFFFF800, 0x00010000]
IMM_EDGES = [0, 1, -1, 2, 31, 2047, -2048, 0x7F, -0x80]

# x2 and x3 point into RAM, x4 at the AXI4-Lite block and x5 at the GPIO register.
# x26 holds the UART's address and x27 the timer's, for the handler, which uses
# x28 to x31. Nothing in a random body writes any of them.
RAM_BASES = [2, 3]
AXIL_BASE, GPIO_BASE, UART_BASE, TIMER_BASE = 4, 5, 26, 27
TARGETS = [0, 1] + list(range(6, 26))
# CSRs for random CSR instructions. mtvec is only read: the handler must stay where
# it is. 0xC00 and 0x7C0 do not exist here, so they trap as illegal.
CSR_WRITABLE = [0x300, 0x304, 0x340, 0x341, 0x342, 0x343, 0x344, 0x301, 0x310]
CSR_READ_ONLY = [0x305, 0xF11, 0xF14, 0xF15, 0xC00, 0x7C0]


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
    """One more clock after the last write to an input. Earlier tutorials saw
    cocotb crash at shutdown without it."""
    await FallingEdge(dut.clk)
    dut.hold.value = 0
    dut.uart_rx.value = 1
    await FallingEdge(dut.clk)


def read_hex(path):
    with open(path) as file:
        words = [int(line, 16) for line in file if line.strip()]
    while words and words[-1] == 0:
        words.pop()
    return words


def all_programs():
    """Every program in programs/, as make built it: assembly and C."""
    programs = []
    for path in sorted(glob.glob(os.path.join(HERE, "..", "programs", "*.*"))):
        name, kind = os.path.splitext(os.path.basename(path))
        if kind in (".asm", ".c"):
            programs.append((name + kind, name, read_hex(os.path.join(BUILD, name + ".hex"))))
    return programs


def stop_program(source):
    return asm.assemble("la t0, handler\ncsrw mtvec, t0\n" + source
                        + "\nebreak\nhandler: ebreak\n")[0]


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
        top = 0x14 if rng.random() < 0.85 else 0x20
        base, offset = AXIL_BASE, size * rng.randrange(top // size)
    elif kind < 0.95:
        base, offset = GPIO_BASE, size * rng.randrange(4 // size) + (4 if rng.random() < 0.1 else 0)
    else:
        base, offset = rs1, random_imm(rng) // size * size
    if rng.random() < 0.04:
        offset += 1                                                 # sometimes misaligned
    return base, offset


def handler_words(rng):
    """The random programs' handler, at HANDLER. An exception skips the instruction
    that caused it, except a fetch fault, which has none: that goes to "spin", a
    loop where interrupts still come. The timer moves mtimecmp on by a random
    number of clocks, the same all through one program. The UART's byte is read."""
    delta = rng.randint(60, 600)
    source = f"""
        .org {HANDLER}
handler: csrr  x31, mcause
        bltz   x31, irq
        li     x30, 1
        beq    x31, x30, fetch
        csrr   x31, mepc
        addi   x31, x31, 4
        csrw   mepc, x31
        mret
fetch:  la     x31, spin
        csrw   mepc, x31
        mret
irq:    li     x30, 0x8000000B
        beq    x31, x30, external
        lw     x30, 0(x{TIMER_BASE})
        addi   x30, x30, {delta}
        sw     x30, 8(x{TIMER_BASE})
        mret
external: lw   x30, 4(x{UART_BASE})
        mret
spin:   j      spin
"""
    return asm.assemble(source)[0][HANDLER // 4:]


def random_program(rng):
    """Tutorial 26's random programs, now with CSR instructions and interrupts.

    A prologue points mtvec at the handler, gives every register a value, sets
    the timer to fire soon, and turns on a random choice of the two interrupts.
    Random instructions follow. Nothing keeps the body safe. It branches and jumps
    anywhere in itself, loops forever, writes over its own code, turns interrupts
    on and off, and traps. Each program is cut off after RANDOM_LIMIT steps.
    """
    words = asm.li_words(31, HANDLER, 0) + [asm.i_type(0x305, 31, 1, 0, asm.OP_SYSTEM)]
    for reg in RAM_BASES:
        words += asm.li_words(reg, DATA + 4 * rng.randrange(1024 - 32), 0)
    words += asm.li_words(AXIL_BASE, 0x2000_0000, 0)
    words += asm.li_words(GPIO_BASE, 0x1000_1000, 0)
    words += asm.li_words(UART_BASE, 0x1000_0000, 0)
    words += asm.li_words(TIMER_BASE, 0x1000_3000, 0)
    # mtimecmp: high half 0, then the low half a little way ahead.
    words += [asm.s_type(12, 0, TIMER_BASE, 2, asm.OP_STORE)]
    words += asm.li_words(31, rng.randint(150, 900), 0)
    words += [asm.s_type(8, 31, TIMER_BASE, 2, asm.OP_STORE)]
    words += asm.li_words(31, rng.choice([0x80, 0x800, 0x880, 0x880, 0x880, 0]), 0)
    words += [asm.i_type(0x304, 31, 1, 0, asm.OP_SYSTEM)]          # csrw mie, x31
    if rng.random() < 0.9:
        words += [asm.i_type(0x300, 8, 6, 0, asm.OP_SYSTEM)]       # csrsi mstatus, 8
    for reg in TARGETS[1:] + [28, 29, 30, 31]:
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
        if kind < 0.20:
            name = rng.choice(list(asm.REG_ALU))
            funct3, funct7 = asm.REG_ALU[name]
            word = asm.r_type(funct7, rs2, rs1, funct3, rd, asm.OP_REG)
        elif kind < 0.32:
            name = rng.choice(list(asm.IMM_ALU))
            word = asm.i_type(random_imm(rng), rs1, asm.IMM_ALU[name], rd, asm.OP_IMM)
        elif kind < 0.37:
            name = rng.choice(list(asm.SHIFT_IMM))
            funct3, funct7 = asm.SHIFT_IMM[name]
            word = asm.i_type((funct7 << 5) | rng.randrange(32), rs1, funct3, rd, asm.OP_IMM)
        elif kind < 0.41:
            opcode = rng.choice([asm.OP_LUI, asm.OP_AUIPC])
            word = asm.u_type(rng.getrandbits(20), rd, opcode)
        elif kind < 0.61:
            store = rng.random() < 0.45
            table = asm.STORES if store else asm.LOADS
            name = rng.choice(list(table))
            size = {"b": 1, "h": 2, "w": 4}[name[1]]
            base, offset = random_access(rng, size, rs1)
            if store:
                word = asm.s_type(offset, rs2, base, table[name], asm.OP_STORE)
            else:
                word = asm.i_type(offset, base, table[name], rd, asm.OP_LOAD)
        elif kind < 0.77:
            funct3 = rng.choice(list(asm.BRANCHES.values()))
            if rng.random() < 0.3:
                rs2 = rs1                                          # so equal values happen
            word = asm.b_type(target_offset(here), rs2, rs1, funct3, asm.OP_BRANCH)
        elif kind < 0.82:
            word = asm.j_type(target_offset(here), rd, asm.OP_JAL)
        elif kind < 0.87:
            choice = rng.random()
            if choice < 0.6:                       # an absolute address in the body
                base, offset = 0, 4 * rng.randrange(start, end) + rng.choice([0, 0, 0, 1])
            elif choice < 0.85:                    # a return through ra
                base, offset = 1, 0
            else:                                  # anywhere: usually a fault or a trap
                base, offset = rs1, random_imm(rng)
            word = asm.i_type(offset, base, 0, rd, asm.OP_JALR)
        elif kind < 0.97:
            # A CSR instruction. Writes go only to CSRs that cannot move the handler.
            funct3 = rng.choice(list(asm.CSR_OPS.values()))
            source = rng.randrange(32) if rng.random() < 0.7 else 0
            if rng.random() < 0.7:
                csr = rng.choice(CSR_WRITABLE)
            else:
                csr = rng.choice(CSR_READ_ONLY)
                if rng.random() < 0.8:
                    funct3, source = rng.choice([2, 3, 6, 7]), 0   # a read, which is legal
            word = asm.i_type(csr, source, funct3, rd, asm.OP_SYSTEM)
        elif kind < 0.975:
            word = 0x30200073                      # mret, to wherever mepc points
        elif kind < 0.995:
            word = 0x0000000F | (rng.getrandbits(17) << 15) | (rng.randrange(32) << 7)
        else:
            word = rng.choice([0x00000073, 0x00100073, 0x00000000, 0x02B50533])
        words.append(word)
    return words


def random_data(rng):
    data = {DATA + 4 * n: random_value(rng) for n in range(1024)}
    for index, word in enumerate(handler_words(rng)):
        data[HANDLER + 4 * index] = word
    return data


@cocotb.test()
async def directed_programs(dut):
    """Every program in programs/, assembly and C, with its input, then every kind of
    trap. Each runs until its first EBREAK."""
    start_clock(dut)
    rng = random.Random(cocotb.RANDOM_SEED)
    coverage = Coverage()
    loader = RamLoader(dut)
    sender = UartSender(dut, CLKS_PER_BIT)
    stalls = interrupts = 0

    runs = [(label, words, INPUTS.get(name, b"")) for label, name, words in all_programs()]
    runs += [(f"stop: {label}", stop_program(source), b"") for label, source in STOPS]

    for label, words, text in runs:
        await reset_and_load(dut, loader, words)
        tasks = []

        def prompt(text=text):
            if text:
                tasks.append(cocotb.start_soon(sender.send(text)))

        checker = Lockstep(dut, Iss(SocMemory(words)), loader, label, rng,
                           coverage=coverage, on_prompt=prompt)
        await checker.run(limit=200000)
        if checker.history[-1].name != "EBREAK":
            raise AssertionError(f"{label} did not reach an ebreak")
        for task in tasks:
            task.cancel()
        stalls += checker.stalls
        interrupts += checker.interrupts

    await finish(dut)
    wanted = TRAPS + ["CSRRW", "CSRRS", "CSRRC", "CSRRWI", "CSRRSI", "CSRRCI", "MRET",
                      "IRQ_TIMER", "IRQ_EXTERNAL"]
    missing = coverage.missing(wanted)
    assert not missing, f"never ran: {missing}"
    dut._log.info(f"directed: {len(runs)} programs, {sender.sent} bytes sent, {interrupts} "
                  f"interrupts, {stalls} stalled requests: " + coverage.summary(wanted))


@cocotb.test()
async def random_programs(dut):
    """Random programs with interrupts at random times: the timer at a random
    period, and bytes on the UART at random gaps. Compared at every step, with every
    slave stalling at random."""
    start_clock(dut)
    rng = random.Random(cocotb.RANDOM_SEED)
    coverage = Coverage()
    loader = RamLoader(dut)
    sender = UartSender(dut, CLKS_PER_BIT)
    interrupts = stalls = 0

    for number in range(RANDOM_PROGRAMS):
        words = random_program(rng)
        data = random_data(rng)
        await reset_and_load(dut, loader, words, data)
        count = rng.randint(0, 4)
        gaps = [rng.randint(0, 600) for _ in range(count)]
        task = cocotb.start_soon(sender.send(bytes(rng.getrandbits(8) for _ in range(count)), gaps))
        checker = Lockstep(dut, Iss(SocMemory(words, data)), loader, f"random program {number}",
                           rng, coverage=coverage)
        await checker.run(limit=RANDOM_LIMIT, stop_at_ebreak=False)
        task.cancel()
        interrupts += checker.interrupts
        stalls += checker.stalls

    await finish(dut)
    # Which traps happen depends on the seed. directed_programs takes them all.
    wanted = [name for name in iss.all_classes() if name not in TRAPS]
    missing = coverage.missing(wanted)
    assert not missing, f"never ran: {missing}"
    taken = ", ".join(f"{name} {n}" for name, n in sorted(coverage.interrupted.items()))
    dut._log.info(f"interrupts were taken before: {taken}")
    dut._log.info(f"random, {RANDOM_PROGRAMS} programs, {sender.sent} bytes sent, "
                  f"{interrupts} interrupts, {stalls} stalled requests: "
                  + coverage.summary(wanted))
