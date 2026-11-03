"""The lockstep checker: runs one CPU and one Iss side by side, and stops at the first
difference. It knows nothing of the FSM. All it uses is:

    On dut:   clk, rst, retire, halted, illegal, dmem_we, dmem_addr, dmem_wdata,
              and the memories imem and dmem, to load a program.
    On probe: retire_pc(), retire_instr(), registers(), flags().

Everything is sampled on the falling clock edge. On that edge, while retire is high,
probe must show the state just after the retiring instruction, and no later one. A
CPU that writes its state at other times gets its own probe class.

This has run on the multi-cycle CPU of Tutorial 17 with write_lag 0, and on the pipeline
of Tutorial 20 with write_lag 2. Tutorial 20 changed one thing: the end of a program now
checks that no write is left unmatched, which write_lag above 0 had let through.
"""

from collections import deque

from cocotb.triggers import FallingEdge

from iss import ILLEGAL_NAMES, all_classes, disassemble


class CpuProbe:
    """How to read the course CPU from cocotb. Python can reach any signal inside the
    simulation by its path, so dut.u_cpu.u_regfile.q[2] is register R2. This class is
    the only place that knows such paths."""

    def __init__(self, dut):
        self.cpu = dut.u_cpu

    def retire_pc(self):
        return int(self.cpu.retire_pc.value)

    def retire_instr(self):
        return int(self.cpu.retire_instr.value)

    def registers(self):
        return tuple(int(self.cpu.u_regfile.q[n].value) for n in range(4))

    def flags(self):
        return tuple(int(s.value) for s in (self.cpu.flag_z, self.cpu.flag_c,
                                            self.cpu.flag_n, self.cpu.flag_v))


class Coverage:
    """Counts what actually ran, so a test cannot pass by never reaching something."""

    def __init__(self):
        self.classes = {}
        self.flag_sets = {}

    def record(self, done):
        self.classes[done.name] = self.classes.get(done.name, 0) + 1
        self.flag_sets[done.flags] = self.flag_sets.get(done.flags, 0) + 1

    def add(self, other):
        for name, count in other.classes.items():
            self.classes[name] = self.classes.get(name, 0) + count
        for flags, count in other.flag_sets.items():
            self.flag_sets[flags] = self.flag_sets.get(flags, 0) + count

    def missing(self, reachable):
        """Every class and flag combination that never happened."""
        names = [name for name in all_classes() if name not in self.classes]
        return names + [show_flags(flags) for flags in sorted(reachable - set(self.flag_sets))]

    def summary(self):
        legal = [name for name in all_classes() if name not in ILLEGAL_NAMES]
        rarest = min(legal, key=lambda name: self.classes.get(name, 0))
        return (f"{sum(self.classes.values())} instructions, {len(self.classes)} classes, "
                f"{len(self.flag_sets)} flag combinations, rarest class {rarest} "
                f"with {self.classes.get(rarest, 0)}")


def show_flags(flags):
    return "zcnv=" + "".join(str(bit) for bit in flags)


def difference_report(label, count, done, got_pc, got_instr, got_regs, got_flags, history, why):
    """A readable account of the first difference."""
    lines = [f"LOCKSTEP FAILED in {label}, instruction {count}: {why}",
             f"  model ran  {done.pc:02X}: {done.instr:04X}  {done.text}",
             f"  cpu ran    {got_pc:02X}: {got_instr:04X}  {disassemble(got_instr)}",
             "             model       cpu"]

    def row(name, model_text, cpu_text):
        mark = "" if model_text == cpu_text else "   <-- differs"
        lines.append(f"  {name:<10} {model_text:<11} {cpu_text}{mark}")

    row("pc", f"{done.pc:02X}", f"{got_pc:02X}")
    row("instr", f"{done.instr:04X}", f"{got_instr:04X}")
    for n in range(4):
        row(f"R{n}", f"{done.regs[n]:02X}", f"{got_regs[n]:02X}")
    row("flags", show_flags(done.flags), show_flags(got_flags))

    lines.append("  last instructions, oldest first:")
    lines += [f"    {old.pc:02X}: {old.instr:04X}  {old.text}" for old in history]
    return "\n".join(lines)


async def load_and_reset(dut, words, data=None):
    """Loads both memories, and holds reset for two clocks."""
    dut.rst.value = 1
    for address in range(256):
        dut.imem[address].value = words[address]
        dut.dmem[address].value = data[address] if data else 0
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst.value = 0


async def run_lockstep(dut, probe, model, label, coverage=None, limit=100000,
                       retire_timeout=32, write_lag=0, halt_wait=1):
    """Runs from reset until the model stops or limit instructions have retired. A run
    cut off at limit goes on for write_lag + 1 more retires, which are checked but not
    counted, so that every write from before the limit has had its chance to match.

    retire_timeout  clocks allowed between retires before the CPU counts as stuck
    write_lag       how many retires a memory write may be early or late. A multi-cycle
                    CPU finishes each write before retiring, so here it is 0
    halt_wait       clocks from the retire of HALT or illegal until halted rises
    """
    history = deque(maxlen=8)
    expected_writes = deque()       # (retire count, address, value), from the model
    seen_writes = deque()           # (retire count, address, value), from the cpu
    count = 0
    idle = 0

    def match_writes(why_prefix):
        """Writes are compared in order, as soon as both sides have one."""
        while expected_writes and seen_writes:
            _, want_address, want_value = expected_writes.popleft()
            _, got_address, got_value = seen_writes.popleft()
            if (want_address, want_value) != (got_address, got_value):
                raise AssertionError(
                    f"LOCKSTEP FAILED in {label}, instruction {count}: {why_prefix}: model wrote "
                    f"{want_value:02X} to {want_address:02X}, cpu wrote {got_value:02X} to "
                    f"{got_address:02X}\n  last instructions, oldest first:\n" +
                    "\n".join(f"    {old.pc:02X}: {old.instr:04X}  {old.text}" for old in history))

    def check_write_age():
        for side, queue in (("model", expected_writes), ("cpu", seen_writes)):
            if queue and count - queue[0][0] > write_lag:
                _, address, value = queue[0]
                other = "cpu" if side == "model" else "model"
                raise AssertionError(
                    f"LOCKSTEP FAILED in {label}, instruction {count}: the {side} wrote "
                    f"{value:02X} to {address:02X} and the {other} did not\n"
                    "  last instructions, oldest first:\n" +
                    "\n".join(f"    {old.pc:02X}: {old.instr:04X}  {old.text}" for old in history))

    while count < limit + write_lag + 1:
        await FallingEdge(dut.clk)

        if int(dut.dmem_we.value):
            seen_writes.append((count, int(dut.dmem_addr.value), int(dut.dmem_wdata.value)))

        if not int(dut.retire.value):
            idle += 1
            if idle > retire_timeout:
                raise AssertionError(
                    f"LOCKSTEP FAILED in {label}: nothing retired for {retire_timeout} clocks "
                    f"after instruction {count}, with the model at pc={model.pc:02X}, "
                    f"{disassemble(model.words[model.pc])}")
            continue

        idle = 0
        count += 1
        done = model.step()
        if coverage is not None and count <= limit:
            coverage.record(done)

        got_pc, got_instr = probe.retire_pc(), probe.retire_instr()
        got_regs, got_flags = probe.registers(), probe.flags()

        why = None
        if (got_pc, got_instr) != (done.pc, done.instr):
            why = "a different instruction retired"
        elif got_regs != done.regs:
            why = "registers differ"
        elif got_flags != done.flags:
            why = "flags differ"
        if why:
            raise AssertionError(difference_report(label, count, done, got_pc, got_instr,
                                                   got_regs, got_flags, history, why))

        history.append(done)
        if done.write:
            expected_writes.append((count, *done.write))
        match_writes("memory writes differ")
        check_write_age()

        if done.stopped:
            # Nothing can arrive after this, so an unmatched write is now a real failure.
            write_lag = -1
            check_write_age()
            await check_stopped(dut, done, label, halt_wait)
            break

    return min(count, limit)


async def check_stopped(dut, done, label, halt_wait):
    """HALT or illegal: halted rises, illegal is right, and nothing more retires."""
    for _ in range(halt_wait):
        await FallingEdge(dut.clk)
    assert int(dut.halted.value), f"{label}: {done.text} retired, but halted did not rise"
    assert int(dut.illegal.value) == int(done.illegal), f"{label}: illegal is wrong"
    for _ in range(4):
        await FallingEdge(dut.clk)
        assert int(dut.halted.value), f"{label}: the CPU left halted without a reset"
        assert not int(dut.retire.value), f"{label}: a retire after halted"
        assert not int(dut.dmem_we.value), f"{label}: a memory write after halted"
