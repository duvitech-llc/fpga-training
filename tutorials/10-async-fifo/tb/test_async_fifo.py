import random
from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer

WORDS = 4000

# Periods in ps, each twice a prime, so the clocks share no
# factor but 2.
RATIOS = {
    "write_faster": (6274, 10006),
    "read_faster": (10006, 6274),
    "write_much_faster": (2018, 14002),
    "read_much_faster": (14002, 2018),
    "nearly_equal": (10006, 10042),
}


async def reset_both(dut):
    """Hold both resets together across several rising edges of each clock."""
    dut.wr_rst.value = 1
    dut.rd_rst.value = 1
    dut.wr_en.value = 0
    dut.rd_en.value = 0
    for _ in range(3):
        await FallingEdge(dut.wr_clk)
    for _ in range(3):
        await FallingEdge(dut.rd_clk)
    await FallingEdge(dut.wr_clk)
    dut.wr_rst.value = 0
    await FallingEdge(dut.rd_clk)
    dut.rd_rst.value = 0


def traffic_rate():
    """Slow, medium or eager. Changing it now and then fills and drains the FIFO."""
    return random.choice([0.05, 0.5, 1.0])


class Stats:
    def __init__(self):
        self.writes = 0
        self.reads = 0
        self.full_events = 0
        self.empty_events = 0


async def writer(dut, words, model, depth, stats):
    """Drive the write side on falling edges of wr_clk."""
    width = len(dut.wr_data)
    rate = traffic_rate()
    await FallingEdge(dut.wr_clk)
    while stats.writes < words:
        if random.random() < 0.02:
            rate = traffic_rate()
        en = int(random.random() < rate)
        data = random.getrandbits(width)
        dut.wr_en.value = en
        dut.wr_data.value = data
        # full cannot change before the next rising edge of wr_clk.
        if en and int(dut.full.value):
            stats.full_events += 1
        elif en:
            model.append(data)
            stats.writes += 1
            assert len(model) <= depth, "more words accepted than the FIFO holds"
        await FallingEdge(dut.wr_clk)
    dut.wr_en.value = 0


async def reader(dut, words, model, stats):
    """Drive the read side on falling edges of rd_clk."""
    expected = None
    rate = traffic_rate()
    await FallingEdge(dut.rd_clk)
    while stats.reads < words or expected is not None:
        if expected is not None:
            assert dut.rd_data.value == expected, f"word {stats.reads}"
            expected = None
        if random.random() < 0.02:
            rate = traffic_rate()
        en = int(stats.reads < words and random.random() < rate)
        dut.rd_en.value = en
        # empty cannot change before the next rising edge of rd_clk.
        if en and int(dut.empty.value):
            stats.empty_events += 1
        elif en:
            assert model, "a word was read that was never written"
            expected = model.popleft()
            stats.reads += 1
        await FallingEdge(dut.rd_clk)
    dut.rd_en.value = 0


async def run_ratio(dut, wr_period, rd_period):
    cocotb.start_soon(Clock(dut.wr_clk, wr_period, unit="ps").start())
    cocotb.start_soon(Clock(dut.rd_clk, rd_period, unit="ps").start())
    depth = 1 << int(dut.ADDR_WIDTH.value)

    await reset_both(dut)
    assert dut.empty.value == 1
    assert dut.full.value == 0

    # The scoreboard. Only one coroutine runs at a time, so sharing it is safe.
    model = deque()
    stats = Stats()
    write_task = cocotb.start_soon(writer(dut, WORDS, model, depth, stats))
    read_task = cocotb.start_soon(reader(dut, WORDS, model, stats))
    await write_task
    await read_task

    assert not model, "words were left in the scoreboard"
    assert stats.full_events > 0, "the random traffic never reached full"
    assert stats.empty_events > 0, "the random traffic never reached empty"
    dut._log.info(
        f"periods {wr_period} and {rd_period} ps: {stats.writes} writes, "
        f"{stats.reads} reads, {stats.full_events} full events, "
        f"{stats.empty_events} empty events"
    )

    # Words still inside must vanish in a reset of both sides.
    dut.wr_en.value = 1
    for _ in range(3):
        await FallingEdge(dut.wr_clk)
    dut.wr_en.value = 0
    await reset_both(dut)
    await Timer(10 * max(wr_period, rd_period), unit="ps")
    assert dut.empty.value == 1, "a reset did not empty the FIFO"
    assert dut.full.value == 0


@cocotb.test()
async def write_faster(dut):
    """Write clock about 1.6 times faster."""
    await run_ratio(dut, *RATIOS["write_faster"])


@cocotb.test()
async def read_faster(dut):
    """Read clock about 1.6 times faster."""
    await run_ratio(dut, *RATIOS["read_faster"])


@cocotb.test()
async def write_much_faster(dut):
    """Write clock about 7 times faster."""
    await run_ratio(dut, *RATIOS["write_much_faster"])


@cocotb.test()
async def read_much_faster(dut):
    """Read clock about 7 times faster."""
    await run_ratio(dut, *RATIOS["read_much_faster"])


@cocotb.test()
async def nearly_equal(dut):
    """Clocks 0.4 percent apart, so the edges slowly slide past each other."""
    await run_ratio(dut, *RATIOS["nearly_equal"])
