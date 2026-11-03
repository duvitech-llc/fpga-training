"""The lockstep checker for the RV32I core: it runs the core and an Iss side by side,
and stops at the first difference. This is Tutorial 18's lockstep.py, changed in
three ways:

- The core has one memory interface, so this file is also the memory. It answers
  each request after 0 to max_wait clocks, chosen at random, with junk on
  mem_rdata while it waits. It checks the interface rules as it goes.
- The core writes its registers and pc on the edge that ends a retire, not before.
  So the registers are compared on the clock after a retire, which is always a
  fetch clock, when nothing can change them.
- A trap is not a retire. When trap rises, the model must have trapped on the same
  instruction, with the same cause, and nothing may have changed.

Inputs are driven on the falling edge, and outputs are read in the ReadOnly phase
after it, once mem_ready has had its effect on retire.
"""

from collections import deque

from cocotb.triggers import FallingEdge, ReadOnly

from iss import MASK, all_classes, disassemble

MEMORY_BYTES = 65536


class BusMemory:
    """The memory the core sees: 64 KiB of 32-bit words, repeated through the address
    space. Kept apart from the model's memory, so that each side has its own copy."""

    def __init__(self, words=(), data=None):
        self.words = [0] * (MEMORY_BYTES // 4)
        for index, word in enumerate(words):
            self.words[index] = word
        if data:
            for address, word in data.items():
                self.words[address // 4] = word

    def index(self, address):
        return (address % MEMORY_BYTES) // 4

    def read(self, address):
        return self.words[self.index(address)]

    def write(self, address, strobe, data):
        mask = sum(0xFF << (8 * lane) for lane in range(4) if strobe >> lane & 1)
        i = self.index(address)
        self.words[i] = (self.words[i] & ~mask & MASK) | (data & mask)


class CoreProbe:
    """How to read the core from cocotb. The only place that knows paths inside it."""

    def __init__(self, dut):
        self.dut = dut

    def pc(self):
        return int(self.dut.retire_pc.value)

    def instr(self):
        return int(self.dut.retire_instr.value)

    def registers(self):
        return tuple(int(self.dut.u_regs.q[n].value) for n in range(32))


class Coverage:
    """Counts what actually ran, so a test cannot pass by never reaching something."""

    def __init__(self):
        self.classes = {}

    def record(self, done):
        for name in done.classes():
            self.classes[name] = self.classes.get(name, 0) + 1

    def missing(self, skip=()):
        return [name for name in all_classes() if name not in self.classes and name not in skip]

    def summary(self, skip=()):
        names = [name for name in all_classes() if name not in skip]
        rarest = min(names, key=lambda name: self.classes.get(name, 0))
        total = sum(self.classes.get(name, 0) for name in all_classes()
                    if "@" not in name and name != "rd=x0")
        return (f"{total} instructions, {len(self.classes)} classes, rarest class {rarest} "
                f"with {self.classes.get(rarest, 0)}")


def show(done):
    return f"{done.pc:08x}: {done.instr:08x}  {done.text}"


class Lockstep:
    def __init__(self, dut, model, memory, label, rng, max_wait=3, coverage=None,
                 timeout=40):
        self.dut = dut
        self.model = model
        self.memory = memory
        self.label = label
        self.rng = rng
        self.max_wait = max_wait
        self.coverage = coverage
        self.timeout = timeout
        self.probe = CoreProbe(dut)
        self.history = deque(maxlen=6)
        self.count = 0
        self.writes = []            # stores the memory saw since the last retire
        self.waits = 0
        self.busy = False
        self.wait_left = 0
        self.held = None

    def fail(self, why, done=None):
        lines = [f"LOCKSTEP FAILED in {self.label}, instruction {self.count}: {why}"]
        if done is not None:
            lines.append(f"  model ran  {show(done)}")
            lines.append(f"  core ran   {self.probe.pc():08x}: {self.probe.instr():08x}  "
                         f"{disassemble(self.probe.instr())}")
        lines.append("  last instructions, oldest first:")
        lines += [f"    {show(old)}" for old in self.history]
        raise AssertionError("\n".join(lines))

    def serve_memory(self):
        """One falling edge of the memory. Called before ReadOnly."""
        dut = self.dut
        if int(dut.rst.value) or not int(dut.mem_valid.value):
            dut.mem_ready.value = 0
            self.busy = False
            return

        request = (int(dut.mem_instr.value), int(dut.mem_addr.value),
                   int(dut.mem_wdata.value), int(dut.mem_wstrb.value))
        if self.busy and not int(dut.mem_ready.value):
            if request != self.held:
                self.fail(f"the request changed while it waited: {self.held} became {request}")
        if not self.busy or int(dut.mem_ready.value):
            # A new transfer. The last one, if any, finished at the rising edge.
            self.busy = True
            self.held = request
            self.wait_left = self.rng.randint(0, self.max_wait)
            instr, address, wdata, strobe = request
            if address % 4:
                self.fail(f"mem_addr {address:08x} is not a multiple of 4")
            if instr and strobe:
                self.fail("a fetch with a write strobe")

        if self.wait_left:
            self.wait_left -= 1
            self.waits += 1
            dut.mem_ready.value = 0
            dut.mem_rdata.value = self.rng.getrandbits(32)      # junk
            return

        instr, address, wdata, strobe = request
        dut.mem_rdata.value = self.memory.read(address)
        dut.mem_ready.value = 1
        if strobe:
            self.memory.write(address, strobe, wdata)
            mask = sum(0xFF << (8 * lane) for lane in range(4) if strobe >> lane & 1)
            self.writes.append((address, strobe, wdata & mask))

    def compare_state(self, done):
        """The clock after a retire: registers and pc."""
        got = self.probe.registers()
        want = tuple(self.model.x)
        for n in range(32):
            if got[n] != want[n]:
                self.fail(f"x{n} is {got[n]:08x}, and the model has {want[n]:08x}", done)
        if self.probe.pc() != self.model.pc:
            self.fail(f"pc is {self.probe.pc():08x}, and the model has {self.model.pc:08x}",
                      done)

    async def run(self, limit):
        """Runs from reset until a trap, or until limit instructions have retired."""
        dut = self.dut
        idle = 0
        check_after = None          # the instruction whose results show on this clock

        while self.count < limit:
            await FallingEdge(dut.clk)
            self.serve_memory()
            await ReadOnly()

            if check_after is not None:
                self.compare_state(check_after)
                check_after = None

            if int(dut.trap.value):
                done = self.model.step()
                self.count += 1
                if done.trap is None:
                    self.fail("the core trapped, and the model did not", done)
                if (self.probe.pc(), self.probe.instr()) != (done.pc, done.instr):
                    self.fail("a different instruction trapped", done)
                if int(dut.trap_cause.value) != done.trap:
                    self.fail(f"trap cause {int(dut.trap_cause.value)}, and the model has "
                              f"{done.trap}", done)
                if self.writes:
                    self.fail("a trapping instruction wrote memory", done)
                if self.coverage is not None:
                    self.coverage.record(done)
                self.compare_state(done)        # nothing changed
                await self.check_stays_trapped()
                return self.count

            if not int(dut.retire.value):
                idle += 1
                if idle > self.timeout:
                    self.fail(f"nothing retired for {self.timeout} clocks, with the model "
                              f"at {self.model.pc:08x}")
                continue

            idle = 0
            self.count += 1
            done = self.model.step()
            if self.coverage is not None:
                self.coverage.record(done)

            if done.trap is not None:
                self.fail(f"the model trapped with cause {done.trap}, and the core retired", done)
            if (self.probe.pc(), self.probe.instr()) != (done.pc, done.instr):
                self.fail("a different instruction retired", done)

            want = [done.bus_write()] if done.write else []
            if self.writes != want:
                got_text = ", ".join(f"{d:08x} wstrb {s:04b} to {a:08x}" for a, s, d in self.writes)
                want_text = ", ".join(f"{d:08x} wstrb {s:04b} to {a:08x}" for a, s, d in want)
                self.fail(f"memory writes differ: core [{got_text}], model [{want_text}]", done)
            self.writes = []

            self.history.append(done)
            check_after = done

        # The last instruction's results show on the next clock.
        await FallingEdge(dut.clk)
        self.serve_memory()
        await ReadOnly()
        self.compare_state(check_after)
        return self.count

    async def check_stays_trapped(self):
        """After a trap, nothing moves until reset."""
        before = self.probe.registers()
        for _ in range(4):
            await FallingEdge(self.dut.clk)
            self.serve_memory()
            await ReadOnly()
            if not int(self.dut.trap.value):
                self.fail("the core left trap without a reset")
            if int(self.dut.retire.value) or int(self.dut.mem_valid.value):
                self.fail("a retire or a memory request after trap")
        if self.probe.registers() != before:
            self.fail("registers changed after trap")


async def reset(dut):
    """Holds reset for two clocks. Inputs change on the falling edge."""
    await FallingEdge(dut.clk)
    dut.rst.value = 1
    dut.mem_ready.value = 0
    dut.mem_rdata.value = 0
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst.value = 0
