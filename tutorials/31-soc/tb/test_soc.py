"""The whole system-on-chip in lockstep with Tutorial 27's reference model, Iss,
with every slave stalling at random on 3 clocks in 10.

directed_boots boots every flash image that make builds, from reset, through
the boot ROM, and runs the program to its end: the demo with the cache, the DMA
engine and both interrupts all at work, the two interrupt sources at once, the
interrupt latency program, the second boot, and the image with a broken CRC.

random_programs runs Tutorial 27's random programs, changed for this system:
each starts a DMA copy into the RAM its loads and stores use, turns on a random
choice of the timer, the UART and the DMA engine's interrupt, and also loads
from the flash, through the XIP slave. Code runs from RAM, through the cache.
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
from iss import Iss  # noqa: E402
from lockstep import Coverage, Lockstep, RamLoader, UartSender, snoop_ram_writes  # noqa: E402
from soc_model import ROM, SocMemory  # noqa: E402

CLKS_PER_BIT = int(os.environ.get("CLKS_PER_BIT", "16"))
TRAPS = iss.TRAP_NAMES
RANDOM_PROGRAMS = 120
RANDOM_LIMIT = 400        # steps from each random program
BODY = 200
DATA = 0x1000             # the RAM the random loads and stores use, 4 KiB
DMA_SOURCE = 0x2000       # what the random DMA copies come from, 1 KiB
HANDLER = 0x3000
JUMP_TO_ZERO = 0x00000067 # jalr x0, 0(x0): the boot ROM for random programs


def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())


def read_words(path):
    with open(path) as file:
        return [int(line, 16) for line in file if line.strip()]


def read_flash(path):
    """mkflash.py's format: a comment line, then bytes in hex, 16 to a line."""
    data = bytearray()
    with open(path) as file:
        for line in file:
            if not line.startswith("//"):
                data += bytes(int(text, 16) for text in line.split())
    return bytes(data)


def read_exit(name):
    with open(os.path.join(BUILD, f"{name}.exit")) as file:
        return int(file.read(), 16)


def rom_symbols():
    symbols = {}
    with open(os.path.join(BUILD, "boot.lst")) as file:
        for line in file:
            if line.startswith("  ") and " = " in line:
                key, value = line.split(" = ")
                symbols[key.strip()] = int(value, 0)
    return symbols


class Board:
    """The boot ROM and the flash, written through the simulator. Only bytes that
    change are written."""

    def __init__(self, dut):
        self.dut = dut
        self.flash = [None] * 0x1_0000
        self.rom = [None] * 256

    def load_rom(self, words):
        mem = self.dut.u_soc.u_rom.mem
        for index in range(256):
            word = words[index] if index < len(words) else 0
            if self.rom[index] != word:
                mem[index].value = word
                self.rom[index] = word

    def load_flash(self, image):
        mem = self.dut.u_flash.mem
        for address in range(0x1_0000):
            byte = image[address] if address < len(image) else 0xFF
            if self.flash[address] != byte:
                mem[address].value = byte
                self.flash[address] = byte


async def reset(dut, board, loader, rom, flash, ram):
    """Holds reset for two clocks, and loads the memories while it is held."""
    await FallingEdge(dut.clk)
    dut.rst.value = 1
    dut.hold.value = 0
    dut.uart_rx.value = 1
    board.load_rom(rom)
    board.load_flash(flash)
    loader.load(ram)
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


# The images, what each is sent and when, and how each must end: at _exit with 0
# in a0, or at the boot ROM's halt.
BOOTS = [
    ("demo",    "flash_demo.hex",    b"xyz", "dma", "demo"),
    ("irqmix",  "flash_irqmix.hex",  b"q",   ">",   "irqmix"),
    ("irqload", "flash_irqload.hex", b"",    None,  "irqload"),
    ("reboot",  "flash_reboot.hex",  b"",    None,  "second"),
    ("badcrc",  "flash_badcrc.hex",  b"",    None,  None),
]


@cocotb.test()
async def directed_boots(dut):
    """Every flash image, booted from reset and run to its end."""
    start_clock(dut)
    rng = random.Random(cocotb.RANDOM_SEED)
    coverage = Coverage()
    board = Board(dut)
    loader = RamLoader(dut)
    sender = UartSender(dut, CLKS_PER_BIT)
    cocotb.start_soon(snoop_ram_writes(dut, loader))
    rom = read_words(os.path.join(BUILD, "boot.raw"))
    halt = ROM + rom_symbols()["halt"]
    totals = {"steps": 0, "interrupts": 0, "stalls": 0, "units": 0, "hits": 0, "misses": 0}
    fetched = set()

    for label, image, text, when, end in BOOTS:
        flash = read_flash(os.path.join(BUILD, image))
        await reset(dut, board, loader, rom, flash, {})
        tasks = []

        def send(text=text):
            if text and not tasks:
                tasks.append(cocotb.start_soon(sender.send(text, [0] + [640] * (len(text) - 1))))

        model = Iss(SocMemory(rom, flash), pc=ROM)
        checker = Lockstep(dut, model, loader, label, rng, coverage=coverage,
                           on_prompt=send if when == ">" else None,
                           on_dma_uart=send if when == "dma" else None)
        await checker.run(limit=400000)
        for task in tasks:
            task.cancel()
        if checker.stale_stop is not None:
            raise AssertionError(f"{label} stopped at stale code at {checker.stale_stop:08x}")
        last = checker.history[-1]
        want = halt if end is None else read_exit(end)
        if last.name != "EBREAK" or last.pc != want or (end is not None and model.x[10] != 0):
            raise AssertionError(f"{label} ended with {last.name} at {last.pc:08x}, a0 "
                                 f"{model.x[10]:08x}, not EBREAK at {want:08x}")
        dut._log.info(f"{label}: {checker.count} steps, {checker.interrupts} interrupts, "
                      f"{checker.dma_units} DMA units, {checker.hits} hits and "
                      f"{checker.misses} misses, from {sorted(checker.fetched_from)}")
        totals["steps"] += checker.count
        totals["interrupts"] += checker.interrupts
        totals["stalls"] += checker.stalls
        totals["units"] += checker.dma_units
        totals["hits"] += checker.hits
        totals["misses"] += checker.misses
        fetched |= checker.fetched_from

    await finish(dut)
    wanted = ["CSRRW", "CSRRS", "CSRRC", "MRET", "IRQ_TIMER", "IRQ_EXTERNAL", "EBREAK"]
    missing = coverage.missing(wanted)
    assert not missing, f"never ran: {missing}"
    assert fetched == {"ram", "rom", "xip"}, f"fetched only from {fetched}"
    dut._log.info(f"directed: {len(BOOTS)} boots, {totals['steps']} steps in lockstep, "
                  f"{totals['interrupts']} interrupts, {totals['units']} DMA units checked, "
                  f"{totals['hits']} hits and {totals['misses']} misses, "
                  f"{totals['stalls']} stalled requests, {sender.sent} bytes sent")


# ----- Random programs, from Tutorial 27 -----

EDGES = [0, 1, 2, 31, 32, 33, 0x7FF, 0x800, 0x7FFFFFFF, 0x80000000, 0x80000001,
         0xFFFFFFFE, 0xFFFFFFFF, 0xFFFFF800, 0x00010000]
IMM_EDGES = [0, 1, -1, 2, 31, 2047, -2048, 0x7F, -0x80]

# x2 and x3 point into RAM, x4 at the AXI4-Lite block, x5 at the GPIO register,
# x24 into the flash. x25 holds the interrupt controller's address, x26 the
# UART's and x27 the timer's, for the handler, which uses x28 to x31. Nothing in
# a random body writes any of them.
RAM_BASES = [2, 3]
AXIL_BASE, GPIO_BASE, XIP_BASE, INTC_BASE, UART_BASE, TIMER_BASE = 4, 5, 24, 25, 26, 27
TARGETS = [0, 1] + list(range(6, 24))
CSR_WRITABLE = [0x300, 0x304, 0x340, 0x341, 0x342, 0x343, 0x344, 0x301, 0x310]
CSR_READ_ONLY = [0x305, 0xF11, 0xF14, 0xF15, 0xC00, 0x7C0]


def random_value(rng):
    return rng.choice(EDGES) if rng.random() < 0.5 else rng.getrandbits(32)


def random_imm(rng):
    return rng.choice(IMM_EDGES) if rng.random() < 0.4 else rng.randint(-2048, 2047)


def random_access(rng, size, rs1, store):
    kind = rng.random()
    if kind < 0.72:
        base, offset = rng.choice(RAM_BASES), size * rng.randint(-16, 16)
    elif kind < 0.82:
        top = 0x14 if rng.random() < 0.85 else 0x20
        base, offset = AXIL_BASE, size * rng.randrange(top // size)
    elif kind < 0.88:
        base, offset = GPIO_BASE, size * rng.randrange(4 // size) + (4 if rng.random() < 0.1 else 0)
    elif kind < 0.95 and (not store or rng.random() < 0.1):
        base, offset = XIP_BASE, size * rng.randint(-64, 64)       # a store here faults
    else:
        base, offset = rs1, random_imm(rng) // size * size
    if rng.random() < 0.04:
        offset += 1
    return base, offset


def handler_words(rng):
    """Tutorial 27's handler, with the external interrupt now shared: it takes the
    UART's byte, if any, and clears the DMA engine's pending bit."""
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
        li     x30, 2
        sw     x30, 0(x{INTC_BASE})
        mret
spin:   j      spin
"""
    return asm.assemble(source)[0][HANDLER // 4:]


def random_program(rng):
    words = asm.li_words(31, HANDLER, 0) + [asm.i_type(0x305, 31, 1, 0, asm.OP_SYSTEM)]
    for reg in RAM_BASES:
        words += asm.li_words(reg, DATA + 4 * rng.randrange(1024 - 32), 0)
    words += asm.li_words(AXIL_BASE, 0x2000_0000, 0)
    words += asm.li_words(GPIO_BASE, 0x1000_1000, 0)
    words += asm.li_words(XIP_BASE, 0x4000_0000 + 4 * rng.randrange(64, 4000), 0)
    words += asm.li_words(INTC_BASE, 0x1000_8000, 0)
    words += asm.li_words(UART_BASE, 0x1000_0000, 0)
    words += asm.li_words(TIMER_BASE, 0x1000_3000, 0)
    # The DMA engine: a word copy into the RAM the body uses, started now. x30 and
    # x31 are free until the handler first runs.
    if rng.random() < 0.9:
        length = 4 * rng.randint(1, 64)
        words += asm.li_words(30, 0x1000_6000, 0)
        words += asm.li_words(31, DMA_SOURCE + 4 * rng.randrange(256 - 64), 0)
        words += [asm.s_type(0, 31, 30, 2, asm.OP_STORE)]
        words += asm.li_words(31, DATA + 4 * rng.randrange(1024 - 64), 0)
        words += [asm.s_type(4, 31, 30, 2, asm.OP_STORE)]
        words += asm.li_words(31, length, 0)
        words += [asm.s_type(8, 31, 30, 2, asm.OP_STORE)]
        words += asm.li_words(31, 1, 0)
        words += [asm.s_type(12, 31, 30, 2, asm.OP_STORE)]
    # The interrupt controller: a random choice of the UART and the DMA engine.
    words += asm.li_words(31, rng.randrange(4), 0)
    words += [asm.s_type(4, 31, INTC_BASE, 2, asm.OP_STORE)]
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
        return offset + 2 if rng.random() < 0.03 else offset

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
            base, offset = random_access(rng, size, rs1, store)
            if store:
                word = asm.s_type(offset, rs2, base, table[name], asm.OP_STORE)
            else:
                word = asm.i_type(offset, base, table[name], rd, asm.OP_LOAD)
        elif kind < 0.77:
            funct3 = rng.choice(list(asm.BRANCHES.values()))
            if rng.random() < 0.3:
                rs2 = rs1
            word = asm.b_type(target_offset(here), rs2, rs1, funct3, asm.OP_BRANCH)
        elif kind < 0.82:
            word = asm.j_type(target_offset(here), rd, asm.OP_JAL)
        elif kind < 0.87:
            choice = rng.random()
            if choice < 0.6:
                base, offset = 0, 4 * rng.randrange(start, end) + rng.choice([0, 0, 0, 1])
            elif choice < 0.85:
                base, offset = 1, 0
            else:
                base, offset = rs1, random_imm(rng)
            word = asm.i_type(offset, base, 0, rd, asm.OP_JALR)
        elif kind < 0.97:
            funct3 = rng.choice(list(asm.CSR_OPS.values()))
            source = rng.randrange(32) if rng.random() < 0.7 else 0
            if rng.random() < 0.7:
                csr = rng.choice(CSR_WRITABLE)
            else:
                csr = rng.choice(CSR_READ_ONLY)
                if rng.random() < 0.8:
                    funct3, source = rng.choice([2, 3, 6, 7]), 0
            word = asm.i_type(csr, source, funct3, rd, asm.OP_SYSTEM)
        elif kind < 0.975:
            word = 0x30200073
        elif kind < 0.995:
            word = 0x0000000F | (rng.getrandbits(17) << 15) | (rng.randrange(32) << 7)
        else:
            word = rng.choice([0x00000073, 0x00100073, 0x00000000, 0x02B50533])
        words.append(word)
    return words


def random_ram(rng, words):
    image = {index: word & 0xFFFF_FFFF for index, word in enumerate(words)}
    for n in range(1024):
        image[DATA // 4 + n] = random_value(rng)
    for n in range(256):
        image[DMA_SOURCE // 4 + n] = rng.getrandbits(32)
    for index, word in enumerate(handler_words(rng)):
        image[HANDLER // 4 + index] = word
    return image


@cocotb.test()
async def random_programs(dut):
    """Random programs from RAM, with the cache, a DMA copy, loads from the flash,
    and interrupts from the timer, the UART and the DMA engine at random times."""
    start_clock(dut)
    rng = random.Random(cocotb.RANDOM_SEED)
    coverage = Coverage()
    board = Board(dut)
    loader = RamLoader(dut)
    sender = UartSender(dut, CLKS_PER_BIT)
    cocotb.start_soon(snoop_ram_writes(dut, loader))
    rom = [JUMP_TO_ZERO]
    flash = bytes(rng.getrandbits(8) for _ in range(0x1_0000))
    totals = {"steps": 0, "interrupts": 0, "stalls": 0, "units": 0, "stale": 0, "trapped": 0}

    for number in range(RANDOM_PROGRAMS):
        words = random_program(rng)
        image = random_ram(rng, words)
        await reset(dut, board, loader, rom, flash, image)
        memory = SocMemory(rom, flash)
        for index, word in image.items():
            memory.ram[4 * index: 4 * index + 4] = word.to_bytes(4, "little")
        count = rng.randint(0, 4)
        gaps = [rng.randint(0, 600) for _ in range(count)]
        task = cocotb.start_soon(sender.send(bytes(rng.getrandbits(8) for _ in range(count)), gaps))
        checker = Lockstep(dut, Iss(memory, pc=ROM), loader, f"random program {number}", rng,
                           coverage=coverage)
        await checker.run(limit=RANDOM_LIMIT, stop_at_ebreak=False)
        task.cancel()
        totals["steps"] += checker.count
        totals["interrupts"] += checker.interrupts
        totals["stalls"] += checker.stalls
        totals["units"] += checker.dma_units
        totals["stale"] += checker.stale_stop is not None

    await finish(dut)
    wanted = [name for name in iss.all_classes() if name not in TRAPS]
    missing = coverage.missing(wanted)
    assert not missing, f"never ran: {missing}"
    taken = ", ".join(f"{name} {n}" for name, n in sorted(coverage.interrupted.items()))
    dut._log.info(f"interrupts were taken before: {taken}")
    dut._log.info(f"random: {RANDOM_PROGRAMS} programs, {totals['steps']} steps in lockstep, "
                  f"{totals['interrupts']} interrupts, {totals['units']} DMA units checked, "
                  f"{totals['stale']} stopped at stale code, {totals['stalls']} stalled requests, "
                  f"{sender.sent} bytes sent")
