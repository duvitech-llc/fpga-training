import math
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

PULSES = 1000
RESETS = 50

# Periods in ps, each twice an odd prime. Half periods are then odd, so a falling
# edge of one clock never lands on a rising edge of the other.
RATIOS = {
    "a_faster": (6274, 10006),
    "b_faster": (10006, 6274),
    "a_much_faster": (2018, 14002),
    "b_much_faster": (14002, 2018),
    "nearly_equal": (10006, 10042),
}


def documented_gap(a_period, b_period):
    """Clocks of clk_a in two periods of clk_b, and at least 2."""
    return max(2, math.ceil(2 * b_period / a_period))


async def start(dut, a_period, b_period):
    """Start both clocks and hold a long reset across several edges of each."""
    dut.arst.value = 0
    dut.a_level.value = 0
    dut.a_pulse.value = 0
    cocotb.start_soon(Clock(dut.clk_a, a_period, unit="ps").start())
    cocotb.start_soon(Clock(dut.clk_b, b_period, unit="ps").start())
    await Timer(1, unit="ps")
    await reset_long(dut)


async def reset_long(dut):
    dut.arst.value = 1
    for _ in range(3):
        await FallingEdge(dut.clk_a)
    for _ in range(3):
        await FallingEdge(dut.clk_b)
    await FallingEdge(dut.clk_a)
    dut.arst.value = 0
    await settle(dut)


async def settle(dut):
    for _ in range(4):
        await FallingEdge(dut.clk_a)
    for _ in range(6):
        await FallingEdge(dut.clk_b)
    await FallingEdge(dut.clk_a)


class Counts:
    def __init__(self):
        self.sent = 0
        self.toggle = 0
        self.naive = 0
        self.at_minimum = 0
        self.level_changes = 0
        self.running = True


async def pulse_monitor(dut, counts):
    """One sample per cycle of clk_b, as logic in that domain would take it."""
    while True:
        await FallingEdge(dut.clk_b)
        counts.toggle += int(dut.b_pulse.value)
        counts.naive += int(dut.b_naive.value)


async def send_pulses(dut, pulses, gap, counts, extra=3):
    """Pulses on falling edges of clk_a, gap or more clocks apart."""
    await FallingEdge(dut.clk_a)
    for _ in range(pulses):
        dut.a_pulse.value = 1
        counts.sent += 1
        await FallingEdge(dut.clk_a)
        dut.a_pulse.value = 0
        # At least half of the pulses sit exactly on the limit: half by choice, and some of
        # the rest by chance. With extra=3 that is 5 in 8, with extra=1 3 in 4, and with
        # extra=0 all of them.
        wait = random.choice([gap, gap + random.randrange(extra + 1)])
        counts.at_minimum += wait == gap
        for _ in range(wait - 1):
            await FallingEdge(dut.clk_a)


async def level_driver(dut, b_clocks, counts):
    """Random levels, from one clock of clk_a up to several clocks of clk_b."""
    while counts.running:
        for _ in range(random.randrange(1, b_clocks)):
            await FallingEdge(dut.clk_a)
        dut.a_level.value = int(dut.a_level.value) ^ 1
        counts.level_changes += 1


async def level_checker(dut):
    """b_level must be a_level from exactly two rising edges of clk_b ago."""
    model = [0, 0]
    while True:
        await RisingEdge(dut.clk_b)
        sampled = int(dut.a_level.value)
        await FallingEdge(dut.clk_b)
        model = [sampled, model[0]]
        assert dut.b_level.value == model[1], "b_level is not a_level from two edges ago"


async def run_ratio(dut, a_period, b_period):
    await start(dut, a_period, b_period)
    counts = Counts()
    gap = documented_gap(a_period, b_period)
    monitor = cocotb.start_soon(pulse_monitor(dut, counts))
    checker = cocotb.start_soon(level_checker(dut))
    driver = cocotb.start_soon(level_driver(dut, 4 * gap + 2, counts))

    await send_pulses(dut, PULSES, gap, counts)
    counts.running = False
    await driver
    await settle(dut)
    monitor.cancel()
    checker.cancel()

    assert counts.toggle == counts.sent, (
        f"sent {counts.sent} above the documented spacing, received {counts.toggle}"
    )
    assert counts.at_minimum > 0, "no pulse was sent at the documented limit"
    assert counts.level_changes > 0, "the level never changed"
    dut._log.info(
        f"periods {a_period} and {b_period} ps, gap {gap}: sent {counts.sent}, "
        f"pulse_sync {counts.toggle}, naive {counts.naive}, "
        f"{counts.at_minimum} at the limit, {counts.level_changes} level changes"
    )
    return counts


@cocotb.test()
async def a_faster(dut):
    """clk_a about 1.6 times faster."""
    await run_ratio(dut, *RATIOS["a_faster"])


@cocotb.test()
async def b_faster(dut):
    """clk_b about 1.6 times faster."""
    await run_ratio(dut, *RATIOS["b_faster"])


@cocotb.test()
async def a_much_faster(dut):
    """clk_a about 7 times faster. The naive crossing must lose pulses here."""
    counts = await run_ratio(dut, *RATIOS["a_much_faster"])
    assert counts.naive < counts.sent, "the naive crossing lost nothing"


@cocotb.test()
async def b_much_faster(dut):
    """clk_b about 7 times faster."""
    await run_ratio(dut, *RATIOS["b_much_faster"])


@cocotb.test()
async def nearly_equal(dut):
    """Clocks 0.4 percent apart, so the edges slowly slide past each other."""
    await run_ratio(dut, *RATIOS["nearly_equal"])


@cocotb.test()
async def below_the_limit(dut):
    """Pulses closer together than one period of clk_b must be seen to vanish."""
    a_period, b_period = RATIOS["a_much_faster"]
    await start(dut, a_period, b_period)
    counts = Counts()
    monitor = cocotb.start_soon(pulse_monitor(dut, counts))
    await send_pulses(dut, PULSES, 2, counts, extra=1)
    await settle(dut)
    monitor.cancel()
    dut._log.info(f"below the limit: sent {counts.sent}, received {counts.toggle}")
    assert counts.toggle < counts.sent, "no pulse was lost below the limit"


async def edges_until_low(clk, rst):
    edges = 0
    while int(rst.value):
        await RisingEdge(clk)
        await Timer(1, unit="ps")
        edges += 1
    return edges


@cocotb.test()
async def reset_fan_out(dut):
    """Random resets: assertion needs no clock, release takes two edges per domain."""
    a_period, b_period = RATIOS["a_faster"]
    await start(dut, a_period, b_period)
    counts = Counts()
    monitor = cocotb.start_soon(pulse_monitor(dut, counts))
    toggle_high = 0
    b_last = 0

    for _ in range(RESETS):
        await send_pulses(dut, random.randint(1, 3), documented_gap(a_period, b_period),
                          counts, extra=0)
        await settle(dut)
        assert counts.toggle == counts.sent, "a pulse was lost before the reset"
        toggle_high += int(dut.pulse.src_toggle.value)

        # Any moment at all, including between edges of both clocks.
        await Timer(random.randrange(1, a_period + b_period), unit="ps")
        dut.arst.value = 1
        await Timer(1, unit="ps")
        assert dut.rst_a.value == 1 and dut.rst_b.value == 1, "assertion waited for a clock"

        # A long reset. Released on a falling edge of clk_a, so no rising edge of
        # either clock can land on the release.
        for _ in range(3):
            await FallingEdge(dut.clk_a)
        for _ in range(3):
            await FallingEdge(dut.clk_b)
        await FallingEdge(dut.clk_a)
        dut.arst.value = 0
        await Timer(1, unit="ps")
        a_task = cocotb.start_soon(edges_until_low(dut.clk_a, dut.rst_a))
        b_task = cocotb.start_soon(edges_until_low(dut.clk_b, dut.rst_b))
        assert await a_task == 2, "rst_a did not fall on the second rising edge of clk_a"
        assert await b_task == 2, "rst_b did not fall on the second rising edge of clk_b"
        await settle(dut)
        assert counts.toggle == counts.sent, "a reset made a phantom pulse"

    monitor.cancel()
    assert toggle_high > 0, "no reset ever arrived with the toggle high"
    dut._log.info(f"{RESETS} resets, {toggle_high} with the toggle high, {counts.sent} pulses")
