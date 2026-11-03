import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge


@cocotb.test()
async def random_inputs(dut):
    """Compare q and serial_out against a Python model of the shift register."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    width = int(dut.WIDTH.value)
    mask = (1 << width) - 1

    dut.rst.value = 1
    dut.load.value = 0
    dut.en.value = 0
    dut.parallel_in.value = 0
    dut.serial_in.value = 0
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    expected = 0

    # The cases that matter, counted so that the test fails if they never happen.
    rst_beat_load = 0
    load_beat_en = 0
    crossings = 0  # a bit went all the way through, with no load or reset in between
    shifts_in_a_row = 0

    for _ in range(20000):
        # Reset and load are rare, otherwise a bit would seldom get all the way through.
        rst = int(random.random() < 0.02)
        load = int(random.random() < 0.1)
        en = int(random.random() < 0.7)
        parallel_in = random.getrandbits(width)
        serial_in = random.getrandbits(1)
        dut.rst.value = rst
        dut.load.value = load
        dut.en.value = en
        dut.parallel_in.value = parallel_in
        dut.serial_in.value = serial_in

        await FallingEdge(dut.clk)

        if rst:
            expected = 0
            rst_beat_load += load
            shifts_in_a_row = 0
        elif load:
            expected = parallel_in
            load_beat_en += en
            shifts_in_a_row = 0
        elif en:
            expected = ((expected << 1) | serial_in) & mask
            shifts_in_a_row += 1
            if shifts_in_a_row == width:
                crossings += 1
                shifts_in_a_row = 0

        inputs = f"rst={rst} load={load} en={en} parallel_in={parallel_in} serial_in={serial_in}"
        assert dut.q.value == expected, inputs
        assert dut.serial_out.value == expected >> (width - 1), inputs

    assert rst_beat_load > 0, "reset and load never happened together"
    assert load_beat_en > 0, "load and en never happened together"
    assert crossings > 0, "no bit ever went all the way through"
    dut._log.info(
        f"WIDTH={width} crossings={crossings} "
        f"rst_beat_load={rst_beat_load} load_beat_en={load_beat_en}"
    )
