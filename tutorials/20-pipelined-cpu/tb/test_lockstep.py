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
from iss import ALU_NAMES, ONE_REGISTER, Iss, fields  # noqa: E402
from lockstep import Coverage, CpuProbe, load_and_reset, run_lockstep  # noqa: E402

RANDOM_PROGRAMS = 300
RANDOM_LIMIT = 300        # instructions from each random program
CLOCK_PROGRAMS = 60       # random programs in the clock model test
MAX_GAP = 32              # clocks between retires before the CPU counts as stuck

# A store is on the bus in MEM, and its own retire is two clocks after that. Two older
# instructions can retire before it does, so a write may be seen 2 retires early. At 1,
# a correct CPU fails.
WRITE_LAG = 2

# Bits each op ignores, which get junk. Spec: "the hardware ignores unused fields".
UNUSED_BITS = {0x0: 0x0F00, 0x1: 0x00F0, 0x2: 0x0300, 0x3: 0x0300, 0x4: 0x0300, 0x5: 0x0300,
               0x8: 0x0F00, 0xA: 0x0F00, 0xB: 0x0FFF, 0xC: 0x0CFF, 0xD: 0x03FF, 0xE: 0x0CFF}

# One word of each illegal kind, and HALT with junk in the fields it ignores.
STOP_WORDS = [0x0002, 0x0FFF, 0x100F, 0x1FFF, 0x9C10, 0x9F00, 0xF000, 0xFFFF, 0x0701]

# Bytes where sums and flags change behaviour. Half of all data is picked from these.
EDGES = [0x00, 0x01, 0x02, 0x7E, 0x7F, 0x80, 0x81, 0xFE, 0xFF]

# Every {z, c, n, v} that can exist. Only 9 of the 16.
REACHABLE = iss.reachable_flags()

# Every hazard the design handles. run_events adds to these, across the tests.
EVENT_NAMES = [
    "forward rd from MEM", "forward rd from WB", "bypass rd in ID",
    "forward rs from MEM", "forward rs from WB", "bypass rs in ID",
    "forward R3 from MEM", "forward R3 from WB", "bypass R3 in ID",
    "forward flags from MEM to branch", "forward flags from WB to branch",
    "forward carry from MEM to ALU", "forward carry from WB to ALU",
    "stall for rd", "stall for rs", "stall for R3",
    "flush by branch", "flush by JMP", "flush by CALL", "flush by JR", "flush by RET",
    "flush by HALT", "flush by illegal",
    "wrong path store", "wrong path load", "wrong path push", "wrong path HALT",
    "wrong path illegal", "wrong path branch", "wrong path POP",
    "POP second trip",
]
events = {name: 0 for name in EVENT_NAMES}


def reads(word):
    """What an instruction reads, from the spec: (set of registers, reads the flags)."""
    op, rd, rs, imm = fields(word)
    if iss.illegal_kind(word):
        return set(), False
    if op == 0x1:
        name = ALU_NAMES[imm % 16]
        used = {rs} if name == "MOV" else {rd} if name in ONE_REGISTER else {rd, rs}
        return used, name in ("ADC", "SBC", "ROL", "ROR")
    if op in (0x3, 0x4, 0x5):
        return {rd}, False
    if op == 0x6:
        return {rs}, False
    if op == 0x7:
        return {rd, rs}, False
    if op == 0x9:
        return set(), True
    if op in (0xA, 0xB, 0xD):
        return {3}, False
    if op == 0xC:
        return {3, rs}, False
    if op == 0xE:
        return {rs}, False
    return set(), False


class PipeProbe(CpuProbe):
    """The pipeline's probe. The registers are read from the same place as in Tutorial 17,
    and that is only safe because of when this CPU retires: one clock after WB, when the
    instruction's writes are visible and the next one's are not. So no shadow copy is
    needed. What this class adds is a look at the hazards as they happen."""

    def flags(self):
        value = int(self.cpu.flags_reg.value)
        return ((value >> 3) & 1, (value >> 2) & 1, (value >> 1) & 1, value & 1)

    def count_forward(self, used, rd, rs, stack, source):
        if stack:
            events[f"forward R3 from {source}"] += 1
        elif used == rd:
            events[f"forward rd from {source}"] += 1
        elif used == rs:
            events[f"forward rs from {source}"] += 1

    def sample(self):
        """Called once a clock. Counts only hazards that mattered: a forward to an
        instruction that ignores that value is not a forward at all."""
        cpu = self.cpu
        ex_word = int(cpu.ex_instr.value)
        id_word = int(cpu.id_instr.value)
        flush, stall = int(cpu.flush.value), int(cpu.stall.value)

        if ex_word:
            op, rd, rs, _ = fields(ex_word)
            stack = op in (0xA, 0xB, 0xC, 0xD)
            used, flags = reads(ex_word)
            a = 3 if stack else rd

            if a in used:
                if int(cpu.forward_a_mem.value):
                    self.count_forward(a, rd, rs, stack, "MEM")
                elif int(cpu.forward_a_wb.value):
                    self.count_forward(a, rd, rs, stack, "WB")
            if rs in used and op != 0xD and op != 0xB and op != 0xA:
                if int(cpu.forward_b_mem.value):
                    self.count_forward(rs, -1, rs, False, "MEM")
                elif int(cpu.forward_b_wb.value):
                    self.count_forward(rs, -1, rs, False, "WB")
            if flags:
                target = "branch" if op == 0x9 else "ALU"
                what = "flags" if op == 0x9 else "carry"
                if int(cpu.forward_flags_mem.value):
                    events[f"forward {what} from MEM to {target}"] += 1
                elif int(cpu.forward_flags_wb.value):
                    events[f"forward {what} from WB to {target}"] += 1

            if flush:
                bad = iss.illegal_kind(ex_word)
                name = ("flush by illegal" if bad else "flush by HALT" if op == 0x0
                        else {0x8: "flush by JMP", 0x9: "flush by branch", 0xA: "flush by CALL",
                              0xB: "flush by RET", 0xE: "flush by JR"}[op])
                events[name] += 1

        if id_word:
            op, rd, rs, _ = fields(id_word)
            stack = op in (0xA, 0xB, 0xC, 0xD)
            used, _ = reads(id_word)
            a = 3 if stack else rd

            if not stall and not flush:
                if a in used and int(cpu.bypass_a.value):
                    events["bypass R3 in ID" if stack else "bypass rd in ID"] += 1
                if rs in used and int(cpu.bypass_b.value) and op not in (0xA, 0xB, 0xD):
                    events["bypass rs in ID"] += 1

            if stall:
                ex_waddr = int(cpu.ex_waddr.value)
                if stack and ex_waddr == 3:
                    events["stall for R3"] += 1
                elif rs in used and ex_waddr == rs:
                    events["stall for rs"] += 1
                else:
                    events["stall for rd"] += 1

        if int(cpu.pop_second.value):
            events["POP second trip"] += 1

        if flush:
            words = []
            if int(cpu.id_valid.value):
                words.append(id_word)
            if not int(cpu.front_stop.value):
                words.append(int(cpu.imem_data.value))
            for word in words:
                op = word >> 12
                name = ("wrong path illegal" if iss.illegal_kind(word)
                        else {0x0: "wrong path HALT" if word & 1 else None,
                              0x6: "wrong path load", 0x7: "wrong path store",
                              0x9: "wrong path branch", 0xA: "wrong path push",
                              0xC: "wrong path push", 0xD: "wrong path POP"}.get(op))
                if name:
                    events[name] += 1


async def watch_events(dut, probe):
    """Runs beside the lockstep checker, until the test ends."""
    while True:
        await FallingEdge(dut.clk)
        if not int(dut.rst.value):
            probe.sample()


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
    """Any legal instruction, with any operands, unchanged from Tutorial 18. Nothing keeps
    a program safe: it can jump anywhere, use R3 for anything, and run off the end."""
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


def rarest_events():
    rarest = sorted(events, key=events.get)[:3]
    return ", ".join(f"{name} with {events[name]}" for name in rarest)


@cocotb.test()
async def directed_programs(dut):
    """Every program, and every kind of stop. This coverage does not depend on a seed."""
    start_clock(dut)
    coverage = Coverage()
    probe = PipeProbe(dut)
    cocotb.start_soon(watch_events(dut, probe))

    for name, words in assemble_all():
        await load_and_reset(dut, words)
        await run_lockstep(dut, probe, Iss(words), name, coverage, write_lag=WRITE_LAG)

    for stop in STOP_WORDS:
        words = [stop] + [0] * 255
        await load_and_reset(dut, words)
        await run_lockstep(dut, probe, Iss(words), f"stop word {stop:04X}", coverage,
                           write_lag=WRITE_LAG)

    missing = coverage.missing(REACHABLE)
    assert not missing, f"never ran: {missing}"
    dut._log.info("directed: " + coverage.summary())


@cocotb.test()
async def random_programs(dut):
    """Wild random programs, compared at every retire. This one also checks that every
    hazard has happened, counting the directed programs too."""
    start_clock(dut)
    rng = random.Random(cocotb.RANDOM_SEED)
    coverage = Coverage()
    probe = PipeProbe(dut)
    cocotb.start_soon(watch_events(dut, probe))

    for number in range(RANDOM_PROGRAMS):
        words = [random_word(rng) for _ in range(256)]
        data = [random_byte(rng) for _ in range(256)]
        await load_and_reset(dut, words, data)
        await run_lockstep(dut, probe, Iss(words, list(data)), f"random program {number}",
                           coverage, limit=RANDOM_LIMIT, write_lag=WRITE_LAG)

    # As in Tutorial 18, an illegal word ends its program, so each kind is rare here.
    missing = [name for name in coverage.missing(REACHABLE) if name not in iss.ILLEGAL_NAMES]
    assert not missing, f"never ran: {missing}"
    dut._log.info(f"random, {RANDOM_PROGRAMS} programs: " + coverage.summary())

    never = [name for name in EVENT_NAMES if events[name] == 0]
    assert not never, f"these hazards never happened: {never}"
    dut._log.info(f"hazards: {len(EVENT_NAMES)} kinds, rarest are {rarest_events()}")
    for name in EVENT_NAMES:
        dut._log.info(f"  {name}: {events[name]}")


def predicted_gap(before, after):
    """Clocks from the retire of one instruction to the retire of the next. This is the
    whole cost of the pipeline, written down."""
    gap = 1
    op, rd, _, _ = fields(before.instr)
    taken_branch = before.name.endswith("_taken") and not before.name.endswith("_not_taken")
    if before.name in ("JMP", "JR", "CALL") or taken_branch:
        gap += 2
    if before.name == "RET":
        gap += 4
    if before.name in ("LD", "POP", "POP_R3") and rd in reads(after.instr)[0]:
        gap += 1
    if after.name in ("POP", "POP_R3"):
        gap += 1
    return gap


@cocotb.test()
async def clock_model(dut):
    """Each gap between retires is exactly what the table in the README says."""
    start_clock(dut)
    rng = random.Random(cocotb.RANDOM_SEED + 1)
    programs = [(name, words, None) for name, words in assemble_all()]
    for number in range(CLOCK_PROGRAMS):
        words = [random_word(rng) for _ in range(256)]
        programs.append((f"random {number}", words, [random_byte(rng) for _ in range(256)]))

    compared = 0
    for name, words, data in programs:
        await load_and_reset(dut, words, data)
        model = Iss(words, list(data) if data else None)
        before, last_clock, clock, retired = None, None, 0, 0

        while not model.stopped and retired < RANDOM_LIMIT:
            await FallingEdge(dut.clk)
            clock += 1
            if not int(dut.retire.value):
                assert clock - (last_clock or 0) < MAX_GAP, f"{name}: nothing is retiring"
                continue
            after = model.step()
            retired += 1
            if before is not None:
                gap = clock - last_clock
                want = predicted_gap(before, after)
                assert gap == want, (f"{name}: {before.text} then {after.text} took {gap} "
                                     f"clocks, and the model says {want}")
                compared += 1
            before, last_clock = after, clock

    dut._log.info(f"clock model: {compared} gaps between retires were as predicted")
