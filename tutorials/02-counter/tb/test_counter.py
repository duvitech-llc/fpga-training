import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer


@cocotb.test()
async def random_inputs(dut):
    """Compare count and wrap against a Python model of the counter for random inputs."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    mod = int(dut.MOD.value)

    dut.rst.value = 1
    dut.en.value = 0
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    expected = 0
    wraps = 0

    for _ in range(5000):
        # Reset is rare, otherwise the count would seldom reach the last value.
        rst = int(random.random() < 0.02)
        en = int(random.random() < 0.8)
        dut.rst.value = rst
        dut.en.value = en

        # wrap is combinational, so it can be checked before the rising edge.
        await Timer(1, unit="ns")
        expected_wrap = not rst and en and expected == mod - 1
        assert dut.wrap.value == expected_wrap, f"rst={rst} en={en} count={expected}"

        await FallingEdge(dut.clk)

        if rst or expected_wrap:
            expected = 0
        elif en:
            expected += 1
        wraps += expected_wrap
        assert dut.count.value == expected, f"rst={rst} en={en}"

    assert wraps > 0, "the random inputs never reached a wrap"
    dut._log.info(f"MOD={mod} wrapped {wraps} times")
