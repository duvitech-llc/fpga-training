"""cocotb tests of rtl/tmds_encoder.v against tb/tmds_model.py, a Python
encoder written from the DVI 1.0 spec's flow charts.

Inputs change on the falling edge. q is registered, so the character for the
inputs set before a rising edge is read at the next falling edge.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge

from tmds_model import decode, encode, path_to, reachable, token


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst.value = 1
    dut.de.value = 0
    dut.d.value = 0
    dut.c.value = 0
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst.value = 0


class Checker:
    """Sends characters to the encoder and checks each one it returns."""

    def __init__(self, dut):
        self.dut = dut
        self.cnt = 0              # the model's running disparity
        self.count = 0
        self.disp_min = self.disp_max = 0

    async def send(self, de, value):
        dut = self.dut
        dut.de.value = de
        if de:
            dut.d.value = value
            want, self.cnt = encode(value, self.cnt)
        else:
            dut.c.value = value
            want, self.cnt = token(value), 0
        await FallingEdge(dut.clk)
        got = int(dut.q.value)
        assert got == want, f"de={de} value={value:#x}: q={got:010b}, the model has {want:010b}"
        kind, back = decode(got)
        assert kind == ("data" if de else "ctl") and back == value, \
            f"q={got:010b} decodes to {kind} {back:#x}, not {value:#x}"
        self.count += 1
        self.disp_min = min(self.disp_min, self.cnt)
        self.disp_max = max(self.disp_max, self.cnt)


@cocotb.test()
async def every_byte_from_every_state(dut):
    """Each of the 256 bytes, sent from each value cnt can hold."""
    await start(dut)
    chk = Checker(dut)
    states = reachable()
    dut._log.info("cnt can reach %s", states)
    assert states == list(range(-8, 9, 2))
    for target in states:
        steps = path_to(target)
        for d in range(256):
            await chk.send(0, d % 4)            # blanking: cnt back to 0
            for s in steps:
                await chk.send(1, s)
            assert chk.cnt == target
            await chk.send(1, d)
    dut._log.info("every byte from every state: %d characters, %d states, all match the model",
                  chk.count, len(states))
    dut.de.value = 0
    await FallingEdge(dut.clk)    # one more clock after the last write: cocotb 2 needs it


@cocotb.test()
async def random_lines(dut):
    """Random lines of pixels between blanking, as a picture would send them."""
    await start(dut)
    chk = Checker(dut)
    rng = random.Random(33)
    d = 0
    for _ in range(300):
        for _ in range(rng.randint(1, 4)):
            await chk.send(0, rng.randint(0, 3))
        for _ in range(rng.randint(1, 60)):
            # Pictures repeat bytes, so half the time send the last byte again.
            if rng.random() < 0.5:
                d = rng.randint(0, 255)
            await chk.send(1, d)
    dut._log.info("random lines: %d characters; cnt stayed from %d to %d",
                  chk.count, chk.disp_min, chk.disp_max)
    assert -8 <= chk.disp_min and chk.disp_max <= 8
    dut.de.value = 0
    await FallingEdge(dut.clk)
