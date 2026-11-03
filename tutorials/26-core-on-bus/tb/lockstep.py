"""The lockstep checker for the whole system: the core on the bus, run side by side
with SocIss, stopping at the first difference.

This is Tutorial 21's lockstep.py, changed for a real bus:

- The memory is no longer Python. It is the system's own RAM and slaves. This file
  only watches the core's memory interface, and drives the slaves' hold inputs at
  random, so every slave adds wait states.
- Reads from the UART and the counters cannot be predicted, so their words are
  copied from the bus into the model, before the model runs the instruction.
  Everything else the model works out for itself, including the GPIO and
  AXI4-Lite registers.
- A trap may come from the bus: an access fault, with mcause 1, 5 or 7. The
  model must stop on the same instruction with the same cause. For a fetch fault
  only the pc can be compared, since no instruction was read.
- It also watches the Wishbone port between the bridge and the interconnect, and
  checks the rules from Tutorial 22: stb only with cyc, a stalled request held
  still, never ack and err together, and never an answer with nothing owed.

Inputs are driven on the falling edge, and outputs are read in the ReadOnly
phase after it.
"""

from collections import deque

from cocotb.triggers import FallingEdge, ReadOnly

from iss import MASK, all_classes, disassemble
from soc_model import CAUSE_FETCH_FAULT, FAULT_NAMES, region

RAM_WORDS = 0x1_0000 // 4


class RamLoader:
    """Puts programs in the system's RAM through the simulator. It remembers what
    the RAM holds, from what it wrote and from every store the core made, and
    writes only the words that must change."""

    def __init__(self, dut):
        self.dut = dut
        self.shadow = [None] * RAM_WORDS        # None: unknown, so always written

    def load(self, words, data=None):
        image = [0] * RAM_WORDS
        for index, word in enumerate(words):
            image[index] = word & MASK
        for address, word in (data or {}).items():
            image[address // 4] = word & MASK
        mem = self.dut.u_ram.mem
        for index, word in enumerate(image):
            if self.shadow[index] != word:
                mem[index].value = word
                self.shadow[index] = word

    def stored(self, address, strobe, data):
        index = address // 4
        old = self.shadow[index]
        if old is None:
            return
        mask = sum(0xFF << (8 * lane) for lane in range(4) if strobe >> lane & 1)
        self.shadow[index] = (old & ~mask & MASK) | (data & mask)


class Coverage:
    """Counts what actually ran, so a test cannot pass by never reaching something."""

    def __init__(self):
        self.classes = {}

    def record(self, done):
        for name in done.classes():
            self.classes[name] = self.classes.get(name, 0) + 1

    def missing(self, wanted):
        return [name for name in wanted if name not in self.classes]

    def summary(self, wanted):
        rarest = min(wanted, key=lambda name: self.classes.get(name, 0))
        total = sum(self.classes.get(name, 0) for name in all_classes() + FAULT_NAMES
                    if "@" not in name and name != "rd=x0")
        return (f"{total} instructions, {len(self.classes)} classes, rarest class {rarest} "
                f"with {self.classes.get(rarest, 0)}")


def show(done):
    return f"{done.pc:08x}: {done.instr:08x}  {done.text}"


class Lockstep:
    def __init__(self, dut, model, loader, label, rng, hold_rate=0.3, coverage=None,
                 timeout=100):
        self.dut = dut
        self.model = model
        self.loader = loader
        self.label = label
        self.rng = rng
        self.hold_rate = hold_rate
        self.coverage = coverage
        self.timeout = timeout
        self.history = deque(maxlen=6)
        self.count = 0
        self.writes = []            # stores the core made since the last retire
        self.held = None            # the core's request, while it waits
        self.wb_owed = 0            # Wishbone requests accepted and not answered
        self.wb_held = None         # a Wishbone request that stalled
        self.stalls = 0
        self.max_owed = 0
        self.data_by_region = {}    # loads and stores that finished, by device

    # ----- Reading the design -----

    def pc(self):
        return int(self.dut.retire_pc.value)

    def instr(self):
        return int(self.dut.retire_instr.value)

    def registers(self):
        return tuple(int(self.dut.u_core.u_regs.q[n].value) for n in range(32))

    def fail(self, why, done=None):
        lines = [f"LOCKSTEP FAILED in {self.label}, instruction {self.count}: {why}"]
        if done is not None:
            lines.append(f"  model ran  {show(done)}")
            lines.append(f"  core ran   {self.pc():08x}: {self.instr():08x}  "
                         f"{disassemble(self.instr())}")
        lines.append("  last instructions, oldest first:")
        lines += [f"    {show(old)}" for old in self.history]
        raise AssertionError("\n".join(lines))

    # ----- One clock -----

    def drive(self):
        """The falling edge: each slave stalls on this clock with chance hold_rate."""
        bits = 0
        for bit in range(7):
            if self.rng.random() < self.hold_rate:
                bits |= 1 << bit
        self.dut.hold.value = bits

    def watch_core(self):
        """The core's side of the bridge, in ReadOnly. A transfer seen here happens at
        the next rising edge."""
        dut = self.dut
        if int(dut.rst.value) or not int(dut.mem_valid.value):
            self.held = None
            return
        request = (int(dut.mem_instr.value), int(dut.mem_addr.value),
                   int(dut.mem_wdata.value), int(dut.mem_wstrb.value))
        if self.held is not None and request != self.held:
            self.fail(f"the core's request changed while it waited: {self.held} became {request}")
        instr, address, wdata, strobe = request
        if address % 4:
            self.fail(f"mem_addr {address:08x} is not a multiple of 4")
        if not int(dut.mem_ready.value):
            self.held = request
            return
        self.held = None
        if not instr:
            where = region(address) or "nothing"
            self.data_by_region[where] = self.data_by_region.get(where, 0) + 1
        if strobe:
            mask = sum(0xFF << (8 * lane) for lane in range(4) if strobe >> lane & 1)
            self.writes.append((address, strobe, wdata & mask))
            if region(address) == "ram":
                self.loader.stored(address, strobe, wdata)
        elif region(address) in ("uart", "counters"):
            self.model.mem.observed[address] = int(dut.mem_rdata.value)

    def watch_wishbone(self):
        """The bridge's Wishbone port, in ReadOnly: the rules of Tutorial 22."""
        dut = self.dut
        cyc, stb = int(dut.m_cyc.value), int(dut.m_stb.value)
        ack, err, stall = int(dut.m_ack.value), int(dut.m_err.value), int(dut.m_stall.value)
        if stb and not cyc:
            self.fail("Wishbone stb without cyc")
        if ack and err:
            self.fail("Wishbone ack and err together")
        if cyc and (ack or err) and self.wb_owed == 0:
            self.fail("a Wishbone answer with nothing outstanding")
        request = (int(dut.m_we.value), int(dut.m_adr.value), int(dut.m_sel.value),
                   int(dut.m_dat_w.value))
        if self.wb_held is not None and cyc and request != self.wb_held:
            self.fail(f"a stalled Wishbone request changed: {self.wb_held} became {request}")
        if self.wb_held is not None and cyc and not stb:
            self.fail("a stalled Wishbone request was dropped")
        self.wb_held = request if (cyc and stb and stall) else None
        self.stalls += int(cyc and stb and stall)
        if not cyc:
            self.wb_owed = 0
        else:
            self.wb_owed += int(stb and not stall) - int(ack or err)
        self.max_owed = max(self.max_owed, self.wb_owed)

    async def clock(self):
        await FallingEdge(self.dut.clk)
        self.drive()
        await ReadOnly()
        self.watch_core()
        self.watch_wishbone()

    # ----- Comparing with the model -----

    def compare_state(self, done):
        """The clock after a retire: registers and pc."""
        got = self.registers()
        want = tuple(self.model.x)
        for n in range(32):
            if got[n] != want[n]:
                self.fail(f"x{n} is {got[n]:08x}, and the model has {want[n]:08x}", done)
        if self.pc() != self.model.pc:
            self.fail(f"pc is {self.pc():08x}, and the model has {self.model.pc:08x}", done)

    async def run(self, limit):
        """Runs from reset until a trap, or until limit instructions have retired."""
        dut = self.dut
        idle = 0
        check_after = None

        while self.count < limit:
            await self.clock()

            if check_after is not None:
                self.compare_state(check_after)
                check_after = None

            if int(dut.trap.value):
                done = self.model.step()
                self.count += 1
                if done.trap is None:
                    self.fail(f"the system trapped with cause {int(dut.trap_cause.value)}, "
                              "and the model did not", done)
                if int(dut.trap_cause.value) != done.trap:
                    self.fail(f"trap cause {int(dut.trap_cause.value)}, and the model has "
                              f"{done.trap}", done)
                if self.pc() != done.pc:
                    self.fail("a different instruction trapped", done)
                if done.trap != CAUSE_FETCH_FAULT and self.instr() != done.instr:
                    self.fail("a different instruction trapped", done)
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
            if (self.pc(), self.instr()) != (done.pc, done.instr):
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
        await self.clock()
        self.compare_state(check_after)
        return self.count

    async def check_stays_trapped(self):
        """After a trap, nothing moves until reset, and nothing more goes on the bus."""
        before = self.registers()
        for _ in range(4):
            await self.clock()
            if not int(self.dut.trap.value):
                self.fail("the system left trap without a reset")
            if int(self.dut.retire.value):
                self.fail("a retire after trap")
            if int(self.dut.m_cyc.value):
                self.fail("a Wishbone cycle after trap")
        if self.registers() != before:
            self.fail("registers changed after trap")


async def reset(dut):
    """Holds reset for two clocks. Inputs change on the falling edge."""
    await FallingEdge(dut.clk)
    dut.rst.value = 1
    dut.hold.value = 0
    dut.uart_rx.value = 1
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst.value = 0
