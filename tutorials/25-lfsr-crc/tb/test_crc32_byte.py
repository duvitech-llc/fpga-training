import random
import zlib

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge

MESSAGES = 300


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst.value = 1
    dut.clear.value = 0
    dut.valid.value = 0
    dut.data.value = 0
    await FallingEdge(dut.clk)
    dut.rst.value = 0


@cocotb.test()
async def random_messages(dut):
    """Random messages with random gaps, against zlib.crc32 after every byte."""
    await start(dut)
    total_bytes = 0
    gaps = 0
    for _ in range(MESSAGES):
        dut.clear.value = 1
        await FallingEdge(dut.clk)
        dut.clear.value = 0
        assert dut.crc.value == 0, "CRC of no bytes"

        message = random.randbytes(random.randrange(0, 100))
        for n, byte in enumerate(message):
            # Sometimes valid is low for a clock, and the CRC must not move.
            while random.random() < 0.2:
                dut.valid.value = 0
                dut.data.value = random.getrandbits(8)
                await FallingEdge(dut.clk)
                gaps += 1
            dut.valid.value = 1
            dut.data.value = byte
            await FallingEdge(dut.clk)
            dut.valid.value = 0
            expected = zlib.crc32(message[: n + 1])
            assert dut.crc.value == expected, (
                f"after {n + 1} bytes of {message.hex()}: "
                f"crc={int(dut.crc.value):08x} expected={expected:08x}"
            )
        total_bytes += len(message)

    # Let the last write reach the design. A test that ends with a write still
    # pending made this cocotb build crash with a segmentation fault on exit.
    await FallingEdge(dut.clk)

    assert gaps > 0, "valid was never low"
    dut._log.info(f"{MESSAGES} messages, {total_bytes} bytes, {gaps} idle clocks")
