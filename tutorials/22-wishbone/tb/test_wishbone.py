import random
from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer

SLAVE0 = 0x1000_0000 >> 2  # word addresses
SLAVE1 = 0x2000_0000 >> 2

# (chance per clock of a new command, one_at_a_time, chance per clock of a busy slave)
PHASES = [(0.9, 0, 0.0), (0.9, 0, 0.3), (0.5, 1, 0.3), (1.0, 0, 0.6), (0.7, 0, 0.2)]
CLOCKS_PER_PHASE = 2000


def random_address():
    """A word address of either slave, just past one, or far from both."""
    kind = random.randrange(5)
    reg = random.randrange(4)
    if kind < 2:
        return SLAVE0 + reg
    if kind < 4:
        return SLAVE1 + reg
    return random.choice([SLAVE0 + 4 + reg, SLAVE1 - 1, 0, random.getrandbits(30)])


def slot(adr):
    """Where the model keeps a word, or None if nobody owns the address."""
    if adr >> 2 == SLAVE0 >> 2:
        return adr & 3
    if adr >> 2 == SLAVE1 >> 2:
        return 4 + (adr & 3)
    return None


def merge(old, dat, sel):
    for k in range(4):
        if sel >> k & 1:
            mask = 0xFF << (8 * k)
            old = (old & ~mask) | (dat & mask)
    return old


# A bus that never answers would otherwise leave the drain loops waiting forever.
@cocotb.test(timeout_time=1, timeout_unit="ms")
async def random_traffic(dut):
    """Every answer arrives once, in order, with the right data or err, whatever the wait states."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    dut.rst.value = 1
    dut.one_at_a_time.value = 0
    dut.hold0.value = 0
    dut.hold1.value = 0
    dut.cmd_valid.value = 0
    dut.cmd_we.value = 0
    dut.cmd_adr.value = 0
    dut.cmd_sel.value = 0
    dut.cmd_dat.value = 0
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst.value = 0

    model = [None] * 8   # what each register holds. None: never written in full
    owed = deque()       # the scoreboard: (err expected, read data expected or None)
    outstanding = 0      # requests accepted by the bus and not yet answered
    held = None          # a request that stalled on the last clock
    counts = dict(answers=0, errs=0, partial_writes=0, slave_stalls=0, order_stalls=0,
                  max_outstanding=0)

    async def clock(offer):
        """Drive one clock. offer is a command tuple or None. Returns True if it was taken."""
        nonlocal outstanding, held

        # Drive this clock's inputs. A busy slave is random on every clock, and
        # each clock of hold is a wait state for every request in it.
        dut.hold0.value = int(random.random() < busy)
        dut.hold1.value = int(random.random() < busy)
        if offer is None:
            dut.cmd_valid.value = 0
        else:
            dut.cmd_valid.value = 1
            dut.cmd_we.value, dut.cmd_adr.value, dut.cmd_sel.value, dut.cmd_dat.value = offer

        # hold reaches stall and cmd_ready through logic. After this short wait,
        # everything read here is what the next rising edge samples.
        await Timer(1, unit="ns")
        cyc = int(dut.m_cyc.value)
        stb = int(dut.m_stb.value)
        stall = int(dut.m_stall.value)
        ack = int(dut.m_ack.value)
        err = int(dut.m_err.value)

        # The master's rules.
        assert cyc or not stb, "stb without cyc"
        if held is not None:
            now = (stb, int(dut.m_we.value), int(dut.m_adr.value), int(dut.m_sel.value),
                   int(dut.m_dat_w.value))
            assert now == held, f"a stalled request changed: {held} became {now}"
        held = None

        # The interconnect's rules, as the master sees them.
        assert not (ack and err), "ack and err together"
        if cyc and (ack or err):
            assert outstanding > 0, "an answer with nothing outstanding"
        if cyc and stb and stall:
            held = (stb, int(dut.m_we.value), int(dut.m_adr.value), int(dut.m_sel.value),
                    int(dut.m_dat_w.value))
            if int(dut.u_interconnect.elsewhere.value):
                counts["order_stalls"] += 1
            else:
                counts["slave_stalls"] += 1
        outstanding += int(cyc and stb and not stall) - int(cyc and (ack or err))
        counts["max_outstanding"] = max(counts["max_outstanding"], outstanding)

        # An answer from the last rising edge.
        if int(dut.rsp_valid.value):
            assert owed, "a response with nothing owed"
            want_err, want_dat = owed.popleft()
            got_err = int(dut.rsp_err.value)
            assert got_err == want_err, f"err={got_err}, expected {want_err}"
            if want_dat is not None:
                got = int(dut.rsp_dat.value)
                assert got == want_dat, f"read {got:08x}, expected {want_dat:08x}"
            counts["answers"] += 1
            counts["errs"] += got_err

        taken = offer is not None and int(dut.cmd_ready.value)
        if taken:
            we, adr, sel, dat = offer
            where = slot(adr)
            if where is None:
                owed.append((1, None))
            elif we:
                owed.append((0, None))
                old = model[where]
                if old is None and sel == 0xF:
                    old = 0
                model[where] = merge(old, dat, sel) if old is not None else None
                if sel not in (0x0, 0xF):
                    counts["partial_writes"] += 1
            else:
                owed.append((0, model[where]))

        await FallingEdge(dut.clk)
        return taken

    for p_valid, one_at_a_time, busy in PHASES:
        # The mode only changes between phases, with nothing owed.
        dut.one_at_a_time.value = one_at_a_time
        await clock(None)
        offer = None
        for _ in range(CLOCKS_PER_PHASE):
            if offer is None and random.random() < p_valid:
                sel = random.choice([0xF, 0xF, random.randrange(16)])
                offer = (random.getrandbits(1), random_address(), sel, random.getrandbits(32))
            if await clock(offer):
                offer = None
        while offer is not None:
            if await clock(offer):
                offer = None
        while owed:
            await clock(None)
        await clock(None)
        assert int(dut.m_cyc.value) == 0, "cyc stayed high with nothing owed"

    dut._log.info(" ".join(f"{k}={v}" for k, v in counts.items()))
    for name, value in counts.items():
        assert value > 0, f"{name} never happened"
