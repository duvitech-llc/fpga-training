"""The lockstep checker for the whole system: the core on the bus, run side by side
with SocIss, stopping at the first difference, while the DMA engine shares the bus.

This is Tutorial 26's lockstep.py, changed for a second master:

- The memory is the system's own RAM and slaves. This file watches the core's
  memory interface, and drives the slaves' hold inputs at random, so every slave
  adds wait states.
- Reads from the UART, the counters and the DMA engine's registers cannot be
  predicted, so their words are copied from the bus into the model, before the
  model runs the instruction.
- The DMA engine writes memory behind the core's back. The model must see each of
  those writes before the first instruction that could read what it wrote, and
  not before. The arbiter puts one master on the bus at a time, so every request
  that reaches a slave has a place in one order: the edge that accepted it. This
  file numbers the edges, notes the edge of every DMA write and of every request
  the core makes, and before the model runs an instruction it applies the DMA
  writes accepted before that instruction's last request. Writes accepted later
  wait for a later instruction.
- A trap may come from the bus: an access fault, with mcause 1, 5 or 7. The model
  must stop on the same instruction with the same cause.
- It also watches the core's Wishbone port, between the bridge and the arbiter,
  and checks the rules from Tutorial 22 there, and it checks every unit the DMA
  engine copies: the data it writes must be the data it read, in the right lanes.

The limits of this way of keeping the model in step are in the README. In short:
the order is exact for RAM, which takes a write at the edge that accepts it. A DMA
write that a slave makes later, or a DMA write into the instruction the core is
running between its fetch and its load, would not be modelled exactly. The tests
here never do either.

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
        self.edge = 0               # the rising edge that requests seen now go out on
        self.cpu_edge = 0           # the edge that took the core's last request
        self.dma_pending = deque()  # DMA writes not yet in the model: (edge, address, sel, data)
        self.dma_read = None        # the word the DMA engine read for this unit, and SRC
        self.dma_units = 0          # units the DMA engine wrote, each checked
        self.dma_applied = 0        # DMA writes applied to the model

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
        for bit in range(8):
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
        elif region(address) in ("uart", "counters", "dma"):
            self.model.mem.observed[address] = int(dut.mem_rdata.value)

    def watch_wishbone(self):
        """The core's Wishbone port, in ReadOnly: the rules of Tutorial 22."""
        dut = self.dut
        cyc, stb = int(dut.cpu_cyc.value), int(dut.cpu_stb.value)
        ack, err, stall = int(dut.cpu_ack.value), int(dut.cpu_err.value), int(dut.cpu_stall.value)
        if stb and not cyc:
            self.fail("Wishbone stb without cyc")
        if ack and err:
            self.fail("Wishbone ack and err together")
        if cyc and (ack or err) and self.wb_owed == 0:
            self.fail("a Wishbone answer with nothing outstanding")
        request = (int(dut.cpu_we.value), int(dut.cpu_adr.value), int(dut.cpu_sel.value),
                   int(dut.cpu_dat_w.value))
        if self.wb_held is not None and cyc and request != self.wb_held:
            self.fail(f"a stalled Wishbone request changed: {self.wb_held} became {request}")
        if self.wb_held is not None and cyc and not stb:
            self.fail("a stalled Wishbone request was dropped")
        self.wb_held = request if (cyc and stb and stall) else None
        self.stalls += int(cyc and stb and stall)
        if cyc and stb and not stall:
            self.cpu_edge = self.edge
        if not cyc:
            self.wb_owed = 0
        else:
            self.wb_owed += int(stb and not stall) - int(ack or err)
        self.max_owed = max(self.max_owed, self.wb_owed)

    def watch_dma(self):
        """The DMA engine's master port, in ReadOnly. Each read answered is kept, and
        each write that goes out is checked against it, then queued for the model."""
        dut = self.dut
        if int(dut.rst.value) or not int(dut.dma_cyc.value):
            return
        state = int(dut.u_dma.state.value)
        if state == 3 and int(dut.dma_ack.value):                  # READ_ACK, answered
            self.dma_read = (int(dut.bus_dat_r.value), int(dut.u_dma.src.value))
        if int(dut.dma_stb.value) and not int(dut.dma_stall.value) and int(dut.dma_we.value):
            address = int(dut.dma_adr.value) * 4
            sel, data = int(dut.dma_sel.value), int(dut.dma_dat_w.value)
            if self.dma_read is None:
                self.fail(f"the DMA engine wrote {address:08x} without reading first")
            word, src = self.dma_read
            if int(dut.u_dma.bytes.value):
                byte = (word >> (8 * (src % 4))) & 0xFF
                want = (1 << (int(dut.u_dma.dst.value) % 4), byte * 0x0101_0101)
            else:
                want = (0xF, word)
            if (sel, data) != want:
                self.fail(f"the DMA engine wrote {data:08x} sel {sel:04b} to {address:08x}, "
                          f"and the unit it read gives {want[1]:08x} sel {want[0]:04b}")
            self.dma_read = None
            self.dma_units += 1
            self.dma_pending.append((self.edge, address, sel, data))

    def apply_dma(self):
        """Puts into the model every DMA write that the bus took before the core's
        last request, the one the next instruction depends on."""
        while self.dma_pending and self.dma_pending[0][0] < self.cpu_edge:
            _, address, sel, data = self.dma_pending.popleft()
            self.model.mem.dma_write(address, sel, data)
            self.dma_applied += 1

    async def clock(self):
        await FallingEdge(self.dut.clk)
        self.edge += 1
        self.drive()
        await ReadOnly()
        self.watch_core()
        self.watch_wishbone()
        self.watch_dma()

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
                self.apply_dma()
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
            self.apply_dma()
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
            if int(self.dut.cpu_cyc.value):
                self.fail("a Wishbone cycle from the core after trap")
        if self.registers() != before:
            self.fail("registers changed after trap")


async def snoop_ram_writes(dut, loader):
    """Runs for the whole test. Every write the RAM takes, from either master, goes
    into the loader's copy, so the next program's load knows what the RAM holds,
    even after a DMA copy that went on after its program's checker stopped."""
    while True:
        await FallingEdge(dut.clk)
        await ReadOnly()
        if (int(dut.s_cyc.value) and int(dut.s_stb.value) & 1 and not int(dut.s_stall.value) & 1
                and int(dut.s_we.value)):
            loader.stored((int(dut.s_adr.value) & 0x3FFF) * 4, int(dut.s_sel.value),
                          int(dut.s_dat_w.value))


async def reset(dut):
    """Holds reset for two clocks. Inputs change on the falling edge."""
    await FallingEdge(dut.clk)
    dut.rst.value = 1
    dut.hold.value = 0
    dut.uart_rx.value = 1
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst.value = 0
