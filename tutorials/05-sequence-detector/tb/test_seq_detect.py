import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge

PATTERN = [1, 0, 1, 1]


@cocotb.test()
async def random_inputs(dut):
    """Compare match against the last four bits of a Python history for random inputs."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    dut.rst.value = 1
    dut.en.value = 0
    dut.d.value = 0
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)

    # The model has no states. It keeps the bits and compares them, so it does
    # not share the transition table that the FSM could have wrong.
    history = []
    since_match = None  # bits taken since the last match ended
    matches = 0
    overlaps = 0

    for _ in range(5000):
        # Reset is rare, otherwise four bits would seldom arrive in a row.
        rst = int(random.random() < 0.02)
        en = int(random.random() < 0.8)
        d = random.randint(0, 1)
        dut.rst.value = rst
        dut.en.value = en
        dut.d.value = d

        await FallingEdge(dut.clk)

        if rst:
            history = []
            since_match = None
        elif en:
            history.append(d)
            if since_match is not None:
                since_match += 1
            if history[-4:] == PATTERN:
                matches += 1
                # Under 4 bits apart means the two matches shared a bit.
                if since_match is not None and since_match < 4:
                    overlaps += 1
                since_match = 0

        expected = history[-4:] == PATTERN
        assert dut.match.value == expected, f"rst={rst} en={en} d={d} last bits={history[-4:]}"

    assert matches > 0, "the random inputs never made a match"
    assert overlaps > 0, "the random inputs never made an overlapping match"
    dut._log.info(f"saw {matches} matches, {overlaps} of them overlapping")


@cocotb.test()
async def unused_states_recover(dut):
    """Write each unused state code and check that the next enabled clock leaves it."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    dut.rst.value = 1
    dut.en.value = 0
    dut.d.value = 0
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst.value = 0

    recoveries = 0
    for code in range(5, 8):
        for d in (0, 1):
            # No input sequence reaches these codes, so write one directly.
            dut.state.value = code
            dut.en.value = 1
            dut.d.value = d
            await FallingEdge(dut.clk)
            assert int(dut.state.value) == 0, f"code {code} with d={d} did not go to IDLE"
            assert dut.match.value == 0, f"match went high after code {code}"
            recoveries += 1

    assert recoveries == 6
    dut._log.info(f"recovered {recoveries} times from unused state codes")
