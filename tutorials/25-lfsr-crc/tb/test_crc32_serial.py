import random
import zlib

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge

MESSAGES = 100


@cocotb.test()
async def random_messages(dut):
    """Random messages, bit 0 of each byte first, against zlib.crc32."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst.value = 1
    dut.clear.value = 0
    dut.valid.value = 0
    dut.bit_in.value = 0
    await FallingEdge(dut.clk)
    dut.rst.value = 0

    total_bytes = 0
    for _ in range(MESSAGES):
        dut.clear.value = 1
        await FallingEdge(dut.clk)
        dut.clear.value = 0

        message = random.randbytes(random.randrange(0, 50))
        for n, byte in enumerate(message):
            for i in range(8):
                dut.valid.value = 1
                dut.bit_in.value = (byte >> i) & 1
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

    dut._log.info(f"{MESSAGES} messages, {total_bytes} bytes")
