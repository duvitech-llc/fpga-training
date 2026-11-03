import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge


@cocotb.test()
async def random_inputs(dut):
    """Compare q against a Python model of the flip-flop for random inputs."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    dut.rst.value = 1
    dut.en.value = 0
    dut.d.value = 0
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    expected = 0

    for _ in range(1000):
        rst = int(random.random() < 0.1)
        en = random.randint(0, 1)
        d = random.randint(0, 1)
        dut.rst.value = rst
        dut.en.value = en
        dut.d.value = d

        await FallingEdge(dut.clk)

        if rst:
            expected = 0
        elif en:
            expected = d
        assert dut.q.value == expected, f"rst={rst} en={en} d={d}"
