import random
from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge


def operand(width):
    """Mostly random, with the values that make long carries now and then."""
    top = (1 << width) - 1
    return random.choice([random.getrandbits(width)] * 6 + [0, 1, top, top >> 1])


@cocotb.test()
async def random_valids(dut):
    """Check every result against a scoreboard queue, with random gaps and resets."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    width = int(dut.WIDTH.value)
    stages = int(dut.STAGES.value)
    chunk = width // stages

    dut.rst.value = 1
    dut.in_valid.value = 0
    dut.a.value = 0
    dut.b.value = 0
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)

    scoreboard = deque()    # (clock the add went in, expected total), oldest first
    clock = 0
    last_valid = 0
    back_to_back = 0
    gapped = 0
    stage_carries = 0
    flushed = 0
    results = 0

    async def one_clock(rst, valid, x, y):
        nonlocal clock, results
        dut.rst.value = rst
        dut.in_valid.value = valid
        dut.a.value = x
        dut.b.value = y
        if rst:
            scoreboard.clear()
        elif valid:
            scoreboard.append((clock, x + y))
        await FallingEdge(dut.clk)
        clock += 1

        if int(dut.out_valid.value):
            assert scoreboard, "a result appeared with no add in flight"
            start, total = scoreboard.popleft()
            assert clock - start == stages, f"latency {clock - start}"
            got = (int(dut.carry.value) << width) | int(dut.sum.value)
            assert got == total, f"got {got:#x} expected {total:#x}"
            results += 1
        elif scoreboard:
            assert clock - scoreboard[0][0] < stages, "a result did not appear"

    for n in range(5000):
        # The rate changes, so there are full bursts as well as sparse spells.
        if n % 200 == 0:
            rate = random.choice([0.2, 0.5, 0.9, 1.0])

        # Reset is rare, otherwise few adds would ever get through.
        rst = int(random.random() < 0.005)
        valid = int(random.random() < rate)
        x = operand(width)
        y = operand(width)

        if rst:
            flushed += len(scoreboard)
        elif valid:
            back_to_back += last_valid
            gapped += not last_valid
            low = (1 << chunk) - 1
            stage_carries += stages > 1 and (x & low) + (y & low) > low
        last_valid = valid and not rst

        await one_clock(rst, valid, x, y)

    for _ in range(stages):
        await one_clock(0, 0, 0, 0)

    assert not scoreboard, f"{len(scoreboard)} adds never came out"
    assert back_to_back > 0, "no add followed another on the next clock"
    assert gapped > 0, "no add came after a gap"
    assert stage_carries > 0 or stages == 1, "no carry crossed a stage boundary"
    assert flushed > 0 or stages == 1, "no reset caught an add in flight"
    dut._log.info(
        f"WIDTH={width} STAGES={stages}: {results} results, {back_to_back} back-to-back, "
        f"{gapped} after a gap, {stage_carries} stage carries, {flushed} flushed by reset"
    )
