"""The lockstep checker for the whole system-on-chip: the core, run side by side
with Tutorial 27's Iss, stopping at the first difference, with the cache, the DMA
engine and interrupts all at work, and every slave stalling at random.

Each rule below comes from the tutorial that needed it. This file puts them
together, and changes none of them:

- Tutorial 27: a step is a retire or a trap. After every step the registers, pc
  and the CSRs are compared. Interrupts: in the EXECUTE clock of each
  instruction, the two interrupt lines are recorded, and handed to the model as
  mip when it runs that instruction. The model decides by itself whether to take
  an interrupt, and which. After mem_err the core drops mem_valid for a clock.
- Tutorial 29: the DMA engine writes memory behind the core's back. The arbiter
  puts one master on the bus at a time, so every request has a place in one
  order: the edge that accepted it. Before the model runs an instruction, the
  DMA writes accepted before that instruction's last request on the bus are
  applied to it. Every unit the DMA engine copies is checked: what it writes is
  what it read, in the right lanes.
- Tutorial 30: the model has no cache. Stores, and here DMA writes too, to a line
  the core has fetched from since the last invalidate are remembered. If the
  core then runs such a word, the cache may hand it the old word, which the
  model cannot know, so the comparison stops there, without failing, and says
  so. The cache's far side keeps the core's interface rules, and a miss fetches
  exactly its line, in order.
- Tutorials 26 to 29: reads from devices that change with time are copied from
  the bus into the model. Here that is the UART, the counters, the timer, the
  SPI controller, the DMA engine's registers, the cache's counters and the
  interrupt controller. The CRC unit is not copied: the model works out the CRC
  from the bytes written to it, by the core or by the DMA engine.

What the model therefore does not check is in the README: the interrupt lines
themselves, the bytes the SPI controller reads, and the moment the core samples
the lines.

Inputs are driven on the falling edge, and outputs are read in the ReadOnly
phase after it.
"""

from collections import deque

from cocotb.triggers import FallingEdge, ReadOnly

from iss import CAUSE_FETCH_FAULT, MASK, all_classes, disassemble, mnemonic
from soc_model import CACHECTL, OBSERVED, region

S_EXECUTE = 1
HOLD_BITS = 15
LINE_WORDS = 4
UART_DATA = 0x1000_0004
PROMPT = 0x3E                   # ">": the program wants input
CHECKED_CSRS = {0x300: "mstatus", 0x304: "mie", 0x305: "mtvec", 0x340: "mscratch",
                0x341: "mepc", 0x342: "mcause", 0x343: "mtval"}


class RamLoader:
    """Puts words in the system's RAM through the simulator. It remembers what the
    RAM holds, from what it wrote and from every write the RAM took, and writes
    only the words that must change. From Tutorial 27."""

    def __init__(self, dut):
        self.dut = dut
        self.shadow = [None] * (0x1_0000 // 4)

    def load(self, image):
        mem = self.dut.u_soc.u_ram.mem
        for index in range(len(self.shadow)):
            word = image.get(index, 0)
            if self.shadow[index] != word:
                mem[index].value = word
                self.shadow[index] = word

    def stored(self, index, strobe, data):
        old = self.shadow[index]
        if old is None:
            return
        mask = sum(0xFF << (8 * lane) for lane in range(4) if strobe >> lane & 1)
        self.shadow[index] = (old & ~mask & MASK) | (data & mask)


class Coverage:
    """Counts what actually ran, so a test cannot pass by never reaching something."""

    def __init__(self):
        self.classes = {}
        self.interrupted = {}

    def record(self, done):
        for name in done.classes():
            self.classes[name] = self.classes.get(name, 0) + 1
        if done.interrupt:
            name = mnemonic(done.instr) or "ILLEGAL"
            self.interrupted[name] = self.interrupted.get(name, 0) + 1

    def missing(self, wanted):
        return [name for name in wanted if name not in self.classes]

    def total(self):
        return sum(self.classes.get(name, 0) for name in all_classes()
                   if "@" not in name and name != "rd=x0")


def show(done):
    return f"{done.pc:08x}: {done.instr:08x}  {done.text}  ({done.name})"


class Lockstep:
    def __init__(self, dut, model, loader, label, rng, hold_rate=0.3, coverage=None,
                 timeout=3000, on_prompt=None, on_dma_uart=None):
        self.dut = dut
        self.soc = dut.u_soc
        self.model = model
        self.loader = loader
        self.label = label
        self.rng = rng
        self.hold_rate = hold_rate
        self.coverage = coverage
        self.timeout = timeout
        self.on_prompt = on_prompt          # the core printed ">"
        self.on_dma_uart = on_dma_uart      # the DMA engine wrote to the UART
        self.history = deque(maxlen=8)
        self.count = 0
        self.interrupts = 0
        self.writes = []            # stores the core made since the last step
        self.held = None            # the core's request, while it waits
        self.mip = 0                # the interrupt lines in this instruction's EXECUTE clock
        self.past_err = False
        self.far_held = None        # the cache's request on the far side, while it waits
        self.far_words = []         # words fetched on the far side for this fetch
        self.wb_owed = 0
        self.wb_held = None
        self.stalls = 0
        self.lines_seen = set()     # lines fetched since the last invalidate
        self.stored = set()         # words written after their line was fetched
        self.stale_stop = None
        self.hits = 0
        self.misses = 0
        self.edge = 0               # the rising edge that requests seen now go out on
        self.cpu_edge = 0           # the edge that took the core's last request
        self.dma_pending = deque()  # DMA writes not yet in the model: (edge, address, sel, data)
        self.dma_read = None
        self.dma_units = 0
        self.dma_applied = 0
        self.fetched_from = set()

    # ----- Reading the design -----

    def pc(self):
        return int(self.soc.retire_pc.value)

    def instr(self):
        return int(self.soc.retire_instr.value)

    def registers(self):
        return tuple(int(self.soc.u_core.u_regs.q[n].value) for n in range(32))

    def csrs(self):
        """The CSRs as a program would read them, from the flip-flops in rv_csr.v."""
        c = self.soc.u_core.u_csr
        bit = lambda name: int(getattr(c, name).value)  # noqa: E731
        return {
            0x300: 0x1800 | bit("mstatus_mpie") << 7 | bit("mstatus_mie") << 3,
            0x304: bit("mie_meie") << 11 | bit("mie_mtie") << 7,
            0x305: bit("mtvec_base") << 2,
            0x340: bit("mscratch"),
            0x341: bit("mepc_word") << 2,
            0x342: bit("mcause_irq") << 31 | bit("mcause_code"),
            0x343: bit("mtval"),
        }

    def fail(self, why, done=None):
        lines = [f"LOCKSTEP FAILED in {self.label}, step {self.count}: {why}"]
        if done is not None:
            lines.append(f"  model ran  {show(done)}")
            lines.append(f"  core ran   {self.pc():08x}: {self.instr():08x}  "
                         f"{disassemble(self.instr())}")
        lines.append("  last steps, oldest first:")
        lines += [f"    {show(old)}" for old in self.history]
        raise AssertionError("\n".join(lines))

    # ----- One clock -----

    def drive(self):
        """The falling edge: each slave stalls on this clock with chance hold_rate."""
        bits = 0
        for bit in range(HOLD_BITS):
            if self.rng.random() < self.hold_rate:
                bits |= 1 << bit
        self.dut.hold.value = bits

    def line(self, address):
        return address - address % (4 * LINE_WORDS)

    def watch_core(self):
        """The core's side of the cache, in ReadOnly. A transfer seen here happens at
        the next rising edge."""
        soc = self.soc
        valid = int(soc.mem_valid.value) and not int(self.dut.rst.value)
        if self.past_err and valid:
            self.fail("mem_valid did not fall for a clock after mem_err")
        self.past_err = bool(valid and int(soc.mem_err.value))
        if int(soc.u_core.state.value) == S_EXECUTE:
            self.mip = (int(soc.irq_external.value) << 11) | (int(soc.irq_timer.value) << 7)
        if not valid:
            self.held = None
            return
        request = (int(soc.mem_instr.value), int(soc.mem_addr.value),
                   int(soc.mem_wdata.value), int(soc.mem_wstrb.value))
        if self.held is not None and request != self.held:
            self.fail(f"the core's request changed while it waited: {self.held} became {request}")
        instr, address, wdata, strobe = request
        if address % 4:
            self.fail(f"mem_addr {address:08x} is not a multiple of 4")
        if not int(soc.mem_ready.value):
            self.held = None if int(soc.mem_err.value) else request
            if int(soc.mem_err.value):
                self.far_words = []
            return
        self.held = None
        if instr:
            self.fetch_done(address)
            if region(address) in OBSERVED:         # a jump into a device's registers
                self.model.mem.observed[address] = int(soc.mem_rdata.value)
        elif strobe:
            mask = sum(0xFF << (8 * lane) for lane in range(4) if strobe >> lane & 1)
            self.writes.append((address, strobe, wdata & mask))
            if self.line(address) in self.lines_seen:
                self.stored.add(address)
            if address == CACHECTL:                     # INVALIDATE
                self.stored = set()
                self.lines_seen = set()
            if address == UART_DATA and strobe & 1 and wdata & 0xFF == PROMPT and self.on_prompt:
                self.on_prompt()
        elif region(address) in OBSERVED:
            self.model.mem.observed[address] = int(soc.mem_rdata.value)

    def fetch_done(self, address):
        """A fetch finishes at this edge. Was it a hit, or a whole line?"""
        where = region(address)
        self.lines_seen.add(self.line(address))
        if where in ("ram", "rom", "xip"):
            self.fetched_from.add(where)
            if not self.far_words:
                self.hits += 1
            else:
                self.misses += 1
                first = self.line(address)
                want = [first + 4 * n for n in range(LINE_WORDS)]
                if self.far_words != want:
                    self.fail(f"a miss at {address:08x} fetched "
                              f"{[f'{a:08x}' for a in self.far_words]}, not its line in order")
        self.far_words = []

    def watch_far(self):
        """The cache's far side, in ReadOnly: Tutorial 21's rules, as the core keeps
        them, since rv_wb_bridge relies on them. From Tutorial 30."""
        soc = self.soc
        if int(self.dut.rst.value) or not int(soc.d_valid.value):
            self.far_held = None
            return
        request = (int(soc.d_instr.value), int(soc.d_addr.value), int(soc.d_wdata.value),
                   int(soc.d_wstrb.value))
        if self.far_held is not None and request != self.far_held:
            self.fail(f"the cache's request changed while it waited: {self.far_held} "
                      f"became {request}")
        if request[1] % 4:
            self.fail(f"d_addr {request[1]:08x} is not a multiple of 4")
        if int(soc.d_ready.value) or int(soc.d_err.value):
            self.far_held = None
            if request[0] and int(soc.d_ready.value):
                self.far_words.append(request[1])
        else:
            self.far_held = request

    def watch_wishbone(self):
        """The core's Wishbone port, between the bridge and the arbiter: the rules
        of Tutorial 22. Notes the edge of each request the bus takes."""
        soc = self.soc
        cyc, stb = int(soc.cpu_cyc.value), int(soc.cpu_stb.value)
        ack, err, stall = int(soc.cpu_ack.value), int(soc.cpu_err.value), int(soc.cpu_stall.value)
        if stb and not cyc:
            self.fail("Wishbone stb without cyc")
        if ack and err:
            self.fail("Wishbone ack and err together")
        if cyc and (ack or err) and self.wb_owed == 0:
            self.fail("a Wishbone answer with nothing outstanding")
        request = (int(soc.cpu_we.value), int(soc.cpu_adr.value), int(soc.cpu_sel.value),
                   int(soc.cpu_dat_w.value))
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

    def watch_dma(self):
        """The DMA engine's master port, in ReadOnly. Each read answered is kept,
        and each write that goes out is checked against it, then queued for the
        model. From Tutorial 29."""
        soc = self.soc
        if int(self.dut.rst.value) or not int(soc.dma_cyc.value):
            return
        state = int(soc.u_dma.state.value)
        if state == 3 and int(soc.dma_ack.value):                  # READ_ACK, answered
            self.dma_read = (int(soc.bus_dat_r.value), int(soc.u_dma.src.value))
        if int(soc.dma_stb.value) and not int(soc.dma_stall.value) and int(soc.dma_we.value):
            address = int(soc.dma_adr.value) * 4
            sel, data = int(soc.dma_sel.value), int(soc.dma_dat_w.value)
            if self.dma_read is None:
                self.fail(f"the DMA engine wrote {address:08x} without reading first")
            word, src = self.dma_read
            if int(soc.u_dma.bytes.value):
                byte = (word >> (8 * (src % 4))) & 0xFF
                want = (1 << (int(soc.u_dma.dst.value) % 4), byte * 0x0101_0101)
            else:
                want = (0xF, word)
            if (sel, data) != want:
                self.fail(f"the DMA engine wrote {data:08x} sel {sel:04b} to {address:08x}, "
                          f"and the unit it read gives {want[1]:08x} sel {want[0]:04b}")
            self.dma_read = None
            self.dma_units += 1
            self.dma_pending.append((self.edge, address, sel, data))
            if region(address) == "ram":
                if self.line(address) in self.lines_seen:
                    self.stored.add(address)
            if address == UART_DATA and self.on_dma_uart:
                self.on_dma_uart()

    def apply_dma(self):
        """Puts into the model every DMA write that the bus took before the core's
        last request, the one the next step depends on."""
        while self.dma_pending and self.dma_pending[0][0] < self.cpu_edge:
            _, address, sel, data = self.dma_pending.popleft()
            self.model.mem.dma_write(address, sel, data)
            self.dma_applied += 1

    async def clock(self):
        await FallingEdge(self.dut.clk)
        self.edge += 1
        self.drive()
        await ReadOnly()
        self.watch_far()
        self.watch_core()
        self.watch_wishbone()
        self.watch_dma()

    # ----- Comparing with the model -----

    def compare_state(self, done):
        """The clock after a step: registers, pc and CSRs."""
        got = self.registers()
        want = tuple(self.model.x)
        for n in range(32):
            if got[n] != want[n]:
                self.fail(f"x{n} is {got[n]:08x}, and the model has {want[n]:08x}", done)
        if self.pc() != self.model.pc:
            self.fail(f"pc is {self.pc():08x}, and the model has {self.model.pc:08x}", done)
        for number, value in self.csrs().items():
            if value != self.model.csr_read(number):
                self.fail(f"{CHECKED_CSRS[number]} is {value:08x}, and the model has "
                          f"{self.model.csr_read(number):08x}", done)

    async def run(self, limit, stop_at_ebreak=True):
        """Runs from reset for limit steps, until the first EBREAK, or until the core
        runs a word written since its line was fetched."""
        soc = self.soc
        idle = 0
        check_after = None
        done = None

        while self.count < limit:
            await self.clock()

            if check_after is not None:
                self.compare_state(check_after)
                check_after = None
                if stop_at_ebreak and done.name == "EBREAK":
                    return self.count

            trap, retire = int(soc.trap.value), int(soc.retire.value)
            if not trap and not retire:
                idle += 1
                if idle > self.timeout:
                    self.fail(f"nothing happened for {self.timeout} clocks, with the model "
                              f"at {self.model.pc:08x}")
                continue

            idle = 0
            if (self.model.pc & ~3) in self.stored:
                # The cache may hold the word from before the write. The model
                # cannot know, so the comparison ends here.
                self.stale_stop = self.model.pc
                return self.count
            self.count += 1
            self.apply_dma()
            done = self.model.step(self.mip)
            self.mip = 0
            if self.coverage is not None:
                self.coverage.record(done)

            if trap:
                cause = int(soc.trap_cause.value)
                if done.trap is None:
                    self.fail(f"the core trapped with cause {cause:08x}, and the model did not",
                              done)
                if cause != done.trap:
                    self.fail(f"trap cause {cause:08x}, and the model has {done.trap:08x}", done)
                if self.pc() != done.pc:
                    self.fail("a trap at a different instruction", done)
                if done.trap != CAUSE_FETCH_FAULT and self.instr() != done.instr:
                    self.fail("a trap at a different instruction", done)
                if self.writes:
                    self.fail("a trapping instruction wrote memory", done)
                self.interrupts += done.interrupt
            else:
                if done.trap is not None:
                    self.fail(f"the model trapped with cause {done.trap:08x}, and the core "
                              "retired", done)
                if (self.pc(), self.instr()) != (done.pc, done.instr):
                    self.fail("a different instruction retired", done)
                want = [done.bus_write()] if done.write else []
                if self.writes != want:
                    got_text = ", ".join(f"{d:08x} wstrb {s:04b} to {a:08x}"
                                         for a, s, d in self.writes)
                    want_text = ", ".join(f"{d:08x} wstrb {s:04b} to {a:08x}" for a, s, d in want)
                    self.fail(f"memory writes differ: core [{got_text}], model [{want_text}]",
                              done)
            self.writes = []
            self.history.append(done)
            check_after = done

        # The last step's results show on the next clock.
        await self.clock()
        self.compare_state(check_after)
        return self.count


class UartSender:
    """Drives uart_rx: 8N1 frames, one bit every clks_per_bit clocks, changed on the
    falling edge. From Tutorial 27."""

    def __init__(self, dut, clks_per_bit):
        self.dut = dut
        self.clks_per_bit = clks_per_bit
        self.sent = 0

    async def send(self, data, gaps=None):
        """Sends each byte, with gaps[i] idle clocks before byte i, if given."""
        for index, byte in enumerate(data):
            for _ in range(gaps[index] if gaps else 0):
                await FallingEdge(self.dut.clk)
            bits = [0] + [(byte >> n) & 1 for n in range(8)] + [1]
            for level in bits:
                await FallingEdge(self.dut.clk)
                self.dut.uart_rx.value = level
                for _ in range(self.clks_per_bit - 1):
                    await FallingEdge(self.dut.clk)
            self.sent += 1


async def snoop_ram_writes(dut, loader):
    """Runs for the whole test. Every write the RAM takes, from either master, goes
    into the loader's copy, so the next program's load knows what the RAM holds.
    From Tutorial 29."""
    soc = dut.u_soc
    while True:
        await FallingEdge(dut.clk)
        await ReadOnly()
        if (int(soc.s_cyc.value) and int(soc.s_stb.value) & 1 and not int(soc.s_stall.value) & 1
                and int(soc.s_we.value)):
            loader.stored(int(soc.s_adr.value) & 0x3FFF, int(soc.s_sel.value),
                          int(soc.s_dat_w.value))
