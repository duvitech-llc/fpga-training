"""The lockstep checker for the whole system, with traps and interrupts: the core on
the bus, run side by side with Iss, stopping at the first difference.

This is Tutorial 26's lockstep.py, changed for machine mode:

- A step is a retire or a trap. Each one runs one Iss.step(), and a trap is no
  longer the end: the core and the model both go on, in the handler at mtvec.
- After every step the CSRs are compared too, not only the registers and pc.
- Interrupts. The model has no clock, so it cannot know when a line rises. The
  rule: the core decides about interrupts in the EXECUTE clock of an instruction,
  so the checker records the two interrupt lines in that clock, and hands them to
  the model as mip when it runs that instruction. The model then decides for
  itself, from its own mstatus and mie, whether to take an interrupt. So the
  decision, its priority, mepc, mcause and the change to mstatus are all checked.
  What is not: that the lines rose at the right time. That is the timer's and the
  UART's business, checked by tb_soc.v.
- A fetch that faults has no EXECUTE clock. The model takes the fault first, so
  no lines are needed for it.
- Reads from the UART, the counters and the timer are copied from the bus into the
  model before it runs the instruction, as in Tutorial 26.
- It still checks the Wishbone port, and one new rule of the native interface:
  after mem_err the core drops mem_valid for at least one clock.

Inputs are driven on the falling edge, and outputs are read in the ReadOnly phase
after it.
"""

from collections import deque

from cocotb.triggers import FallingEdge, ReadOnly

from iss import CAUSE_FETCH_FAULT, MASK, all_classes, disassemble, mnemonic
from soc_model import OBSERVED, region

RAM_WORDS = 0x1_0000 // 4
S_EXECUTE = 1
UART_DATA = 0x1000_0004
PROMPT = 0x3E                   # ">": the program wants input
CHECKED_CSRS = {0x300: "mstatus", 0x304: "mie", 0x305: "mtvec", 0x340: "mscratch",
                0x341: "mepc", 0x342: "mcause", 0x343: "mtval"}


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
        self.interrupted = {}       # the instruction an interrupt was taken before, by name

    def record(self, done):
        for name in done.classes():
            self.classes[name] = self.classes.get(name, 0) + 1
        if done.interrupt:
            name = mnemonic(done.instr) or "ILLEGAL"
            self.interrupted[name] = self.interrupted.get(name, 0) + 1

    def missing(self, wanted):
        return [name for name in wanted if name not in self.classes]

    def summary(self, wanted):
        rarest = min(wanted, key=lambda name: self.classes.get(name, 0))
        total = sum(self.classes.get(name, 0) for name in all_classes()
                    if "@" not in name and name != "rd=x0")
        return (f"{total} steps, {len(self.classes)} classes, rarest class {rarest} "
                f"with {self.classes.get(rarest, 0)}")


def show(done):
    return f"{done.pc:08x}: {done.instr:08x}  {done.text}  ({done.name})"


class Lockstep:
    def __init__(self, dut, model, loader, label, rng, hold_rate=0.3, coverage=None,
                 timeout=200, on_prompt=None):
        self.dut = dut
        self.model = model
        self.loader = loader
        self.label = label
        self.rng = rng
        self.hold_rate = hold_rate
        self.coverage = coverage
        self.timeout = timeout
        self.on_prompt = on_prompt  # called when the program prints ">"
        self.history = deque(maxlen=8)
        self.count = 0
        self.interrupts = 0
        self.writes = []            # stores the core made since the last step
        self.held = None            # the core's request, while it waits
        self.mip = 0                # the interrupt lines in this instruction's EXECUTE clock
        self.past_err = False       # mem_err on the last clock
        self.wb_owed = 0            # Wishbone requests accepted and not answered
        self.wb_held = None         # a Wishbone request that stalled
        self.stalls = 0
        self.data_by_region = {}    # loads and stores that finished, by device

    # ----- Reading the design -----

    def pc(self):
        return int(self.dut.retire_pc.value)

    def instr(self):
        return int(self.dut.retire_instr.value)

    def registers(self):
        return tuple(int(self.dut.u_core.u_regs.q[n].value) for n in range(32))

    def csrs(self):
        """The CSRs as a program would read them, built from the flip-flops in rv_csr.v."""
        c = self.dut.u_core.u_csr
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
        for bit in range(8):
            if self.rng.random() < self.hold_rate:
                bits |= 1 << bit
        self.dut.hold.value = bits

    def watch_core(self):
        """The core's side of the bridge, in ReadOnly. A transfer seen here happens at
        the next rising edge."""
        dut = self.dut
        valid = int(dut.mem_valid.value) and not int(dut.rst.value)
        if self.past_err and valid:
            self.fail("mem_valid did not fall for a clock after mem_err")
        self.past_err = bool(valid and int(dut.mem_err.value))
        if int(dut.u_core.state.value) == S_EXECUTE:
            self.mip = (int(dut.irq_external.value) << 11) | (int(dut.irq_timer.value) << 7)
        if not valid:
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
            self.held = None if int(dut.mem_err.value) else request
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
            if address == UART_DATA and strobe & 1 and wdata & 0xFF == PROMPT and self.on_prompt:
                self.on_prompt()
        elif region(address) in OBSERVED:
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

    async def clock(self):
        await FallingEdge(self.dut.clk)
        self.drive()
        await ReadOnly()
        self.watch_core()
        self.watch_wishbone()

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
        """Runs from reset for limit steps, or until the first EBREAK."""
        dut = self.dut
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

            trap, retire = int(dut.trap.value), int(dut.retire.value)
            if not trap and not retire:
                idle += 1
                if idle > self.timeout:
                    self.fail(f"nothing happened for {self.timeout} clocks, with the model "
                              f"at {self.model.pc:08x}")
                continue

            idle = 0
            self.count += 1
            done = self.model.step(self.mip)
            self.mip = 0
            if self.coverage is not None:
                self.coverage.record(done)

            if trap:
                cause = int(dut.trap_cause.value)
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
    falling edge."""

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
