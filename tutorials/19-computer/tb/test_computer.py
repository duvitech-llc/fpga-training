import os
import random
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
import asm  # noqa: E402

CLOCK_PS = 10_000
BUILD = os.path.join(os.path.dirname(__file__), "..", "build")

# The sender's bit period differs from the computer's by up to this much.
MAX_SKEW = 0.02


class BusModel:
    """What the I/O map says must happen, one clock at a time, and what did happen."""

    def __init__(self):
        self.ram = [0] * 240
        self.reset()
        self.reads = {"ram": 0, "status": 0, "rx": 0, "led": 0, "unused": 0}
        self.writes = {"ram": 0, "status": 0, "tx": 0, "led": 0, "unused": 0}
        self.tx_bytes = []       # every byte the transmitter accepted
        self.status_reads = 0
        self.rx_polls = 0        # status reads that found no byte waiting
        self.tx_polls = 0        # status reads that found the transmitter busy
        self.rx_reads = 0
        self.tx_lost = 0
        self.frames_in = 0       # good frames the receiver finished
        self.overruns = 0
        self.first_overrun = None
        self.races = 0           # a byte arrived on the very edge of a read

    def reset(self):
        self.hold = 0
        self.waiting = 0
        self.error = 0
        self.led = 0
        self.expect = None       # the read data due on the next clock


async def scoreboard(dut, model):
    """Checks the bus against the model on every clock.

    A falling edge sees the results of the last rising edge, and the strobes that the
    next rising edge will act on, so each pass checks first and then steps the model.
    """
    while True:
        await FallingEdge(dut.clk)

        if int(dut.rst.value):
            model.reset()
            continue

        tx_ready = int(dut.u_uart.tx_ready.value)
        status = (model.error << 2) | (model.waiting << 1) | tx_ready
        assert int(dut.status.value) == status, (
            f"status {int(dut.status.value):02x}, expected {status:02x}")
        assert int(dut.led.value) == model.led, "LED register differs from the model"
        if model.expect is not None:
            want = status if model.expect == "status" else model.expect
            got = int(dut.dmem_rdata.value)
            assert got == want, f"read data {got:02x}, expected {want:02x}"

        re = int(dut.dmem_re.value)
        we = int(dut.dmem_we.value)
        addr = int(dut.dmem_addr.value)
        wdata = int(dut.dmem_wdata.value)
        rx_valid = int(dut.u_uart.rx_valid.value)
        rx_error = int(dut.u_uart.rx_error.value)
        rx_read = re and addr == 0xF1

        model.expect = None
        if re:
            if addr < 0xF0:
                model.reads["ram"] += 1
                model.expect = model.ram[addr]
            elif addr == 0xF0:
                model.reads["status"] += 1
                model.expect = "status"
                model.status_reads += 1
                model.rx_polls += not model.waiting
                model.tx_polls += not tx_ready
            elif addr == 0xF1:
                model.reads["rx"] += 1
                model.expect = model.hold
                model.rx_reads += 1
            elif addr == 0xF2:
                model.reads["led"] += 1
                model.expect = model.led
            else:
                model.reads["unused"] += 1
                model.expect = 0

        if we:
            if addr < 0xF0:
                model.writes["ram"] += 1
                model.ram[addr] = wdata
            elif addr == 0xF0:
                model.writes["status"] += 1
                model.error = 0
            elif addr == 0xF1:
                model.writes["tx"] += 1
                model.tx_lost += not tx_ready
                if tx_ready:
                    model.tx_bytes.append(wdata)
            elif addr == 0xF2:
                model.writes["led"] += 1
                model.led = wdata
            else:
                model.writes["unused"] += 1

        if rx_error:
            model.error = 1

        if rx_valid:
            model.frames_in += 1
            model.races += bool(rx_read)
            if model.waiting and not rx_read:
                model.overruns += 1
                if model.first_overrun is None:
                    model.first_overrun = model.frames_in
            model.hold = int(dut.u_uart.rx_data.value)
            model.waiting = 1
        elif rx_read:
            model.waiting = 0


async def uart_listener(dut, received, bit_ps):
    """The far end of uart_tx. Knows only the line, and the agreed bit time."""
    while True:
        await FallingEdge(dut.uart_tx)
        await Timer(bit_ps // 2, unit="ps")
        assert int(dut.uart_tx.value) == 0, "the start bit did not last"
        byte = 0
        for i in range(8):
            await Timer(bit_ps, unit="ps")
            byte |= int(dut.uart_tx.value) << i
        await Timer(bit_ps, unit="ps")
        assert int(dut.uart_tx.value) == 1, "the stop bit on uart_tx is low"
        received.append(byte)


async def send_frame(dut, byte, bit_ps, stop=1):
    """Drive one 8N1 frame on uart_rx, with no reference to clk."""
    for level in [0] + [(byte >> i) & 1 for i in range(8)] + [stop]:
        dut.uart_rx.value = level
        await Timer(round(bit_ps), unit="ps")
    dut.uart_rx.value = 1


async def load(dut, words):
    """Hold reset while the instruction memory is filled."""
    dut.rst.value = 1
    for address, word in enumerate(words):
        dut.imem[address].value = word
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst.value = 0


async def start(dut, program):
    """Load a program, reset, and start the model and the listener."""
    cocotb.start_soon(Clock(dut.clk, CLOCK_PS, unit="ps").start())
    dut.uart_rx.value = 1
    for address in range(240):
        dut.ram[address].value = 0
    with open(os.path.join(BUILD, f"{program}.hex")) as file:
        await load(dut, [int(line, 16) for line in file])

    bit_ps = int(dut.CLKS_PER_BIT.value) * CLOCK_PS
    model = BusModel()
    received = []
    cocotb.start_soon(scoreboard(dut, model))
    cocotb.start_soon(uart_listener(dut, received, bit_ps))
    return model, received, bit_ps


async def wait_for(dut, condition, limit, what):
    for _ in range(limit):
        if condition():
            return
        await FallingEdge(dut.clk)
    assert condition(), f"timed out waiting for {what}"


def upper(byte):
    return byte - 32 if 0x61 <= byte <= 0x7A else byte


@cocotb.test()
async def hello(dut):
    """The program prints its string, and must poll to do it."""
    model, received, bit_ps = await start(dut, "hello")
    await wait_for(dut, lambda: int(dut.halted.value), 20_000, "halted")
    await Timer(30 * bit_ps, unit="ps")

    assert bytes(received) == b"hello", f"got {bytes(received)}"
    assert not int(dut.illegal.value)
    assert model.writes["tx"] == 5, f"{model.writes['tx']} writes for 5 letters"
    assert model.tx_polls > 0, "putc never had to wait"
    assert model.tx_lost == 0, "a byte was written while the transmitter was busy"
    dut._log.info(f"line trace: {bytes(received).decode()!r}, "
                  f"{model.status_reads} status reads, {model.tx_polls} found it busy")


@cocotb.test()
async def leds(dut):
    """The LED register, read back and written by a program."""
    model, _, _ = await start(dut, "leds")
    await wait_for(dut, lambda: int(dut.halted.value), 200_000, "halted")
    assert model.writes["led"] == 256, f"{model.writes['led']} writes to the LEDs"
    assert model.reads["led"] == 256, f"{model.reads['led']} reads of the LEDs"
    assert int(dut.led.value) == 0


def random_program():
    """80 random loads and stores, half of them in the I/O space."""
    lines = []
    for _ in range(80):
        address = random.randrange(0xF0, 0x100) if random.random() < 0.5 else random.randrange(0xF0)
        lines.append(f"LDI R1, {address}")
        lines.append(f"LDI R0, {random.randrange(256)}")
        lines.append(random.choice(["ST R0, [R1]", "LD R0, [R1]"]))
    lines.append("HALT")
    return asm.assemble("\n".join(lines))[0]


async def noise(dut, bit_ps):
    """Bytes arriving with no regard for what the program is doing."""
    while True:
        await send_frame(dut, random.randrange(256), bit_ps)
        await Timer(random.randrange(round(30 * bit_ps)) + 1, unit="ps")


@cocotb.test()
async def random_bus(dut):
    """Random reads and writes of every address, while bytes arrive at random."""
    model, received, bit_ps = await start(dut, "race")
    cocotb.start_soon(noise(dut, bit_ps))

    for _ in range(25):
        await load(dut, random_program())
        await wait_for(dut, lambda: int(dut.halted.value), 5000, "halted")
        # Let the last frame finish, so the next reset does not cut it short.
        await wait_for(dut, lambda: int(dut.u_uart.tx_ready.value),
                       int(12 * bit_ps / CLOCK_PS), "the transmitter")
        await Timer(bit_ps, unit="ps")

    # A byte written while the transmitter was busy must not appear on the line.
    assert received == model.tx_bytes, (
        f"{len(received)} bytes on the line, {len(model.tx_bytes)} accepted")
    for kind, count in list(model.reads.items()) + list(model.writes.items()):
        assert count > 0, f"{kind} was never used"
    assert model.tx_lost > 0, "no write ever found the transmitter busy"
    dut._log.info(f"reads {model.reads}, writes {model.writes}, "
                  f"{model.tx_lost} writes lost to a busy transmitter")


@cocotb.test()
async def random_echo(dut):
    """Random strings through echo, with the Python UART on both pins."""
    model, received, bit_ps = await start(dut, "echo")

    expected = []
    sent = 0
    back_to_back = 0
    bad_frames = 0
    letters = 0
    longest = 0

    for _ in range(60):
        length = random.randint(1, 32)
        longest = max(longest, length)
        bit = bit_ps * (1 + random.uniform(-MAX_SKEW, MAX_SKEW))

        for _ in range(length):
            # Never more than one byte ahead of the echo, so the holding register
            # cannot overflow. The full_speed test below takes that limit away.
            await wait_for(dut, lambda: len(received) >= len(expected) - 1,
                           int(40 * bit_ps / CLOCK_PS) + 2000, "the echo to catch up")

            if random.random() < 0.05:
                bad_frames += 1
                await send_frame(dut, random.randrange(256), bit, stop=0)
                await Timer(round(bit), unit="ps")
                continue

            if random.random() < 0.5:
                await Timer(random.randrange(round(3 * bit)), unit="ps")
            else:
                back_to_back += 1

            byte = random.randrange(256)
            letters += 0x61 <= byte <= 0x7A
            expected.append(upper(byte))
            sent += 1
            await send_frame(dut, byte, bit)

    await wait_for(dut, lambda: len(received) >= len(expected),
                   int(40 * bit_ps / CLOCK_PS) + 2000, "the last echo")
    await Timer(20 * bit_ps, unit="ps")

    assert received == expected, f"got {len(received)} bytes, expected {len(expected)}"
    assert not int(dut.halted.value), "echo should run for ever"
    assert model.tx_lost == 0, "a byte was written while the transmitter was busy"
    assert model.overruns == 0, "a byte was overwritten before it was read"
    assert model.rx_reads == sent, f"{model.rx_reads} reads for {sent} bytes"

    assert sent > 0 and len(received) > 0
    assert letters > 0, "no byte was a letter"
    assert bad_frames > 0, "no frame had a bad stop bit"
    assert back_to_back > 0, "no two frames were back to back"
    assert model.rx_polls > 0, "getc never had to wait"
    assert model.tx_polls > 0, "putc never had to wait"
    dut._log.info(f"{sent} bytes in, {len(received)} bytes out, {letters} letters, "
                  f"{bad_frames} bad frames, {model.status_reads} status reads "
                  f"({model.rx_polls} no byte yet, {model.tx_polls} transmitter busy)")


@cocotb.test()
async def read_races(dut):
    """Bytes landing on the same edge as a read, which the scoreboard checks."""
    model, _, bit_ps = await start(dut, "race")

    for _ in range(600):
        await Timer(random.randrange(round(5 * bit_ps)) + 1, unit="ps")
        await send_frame(dut, random.randrange(256), bit_ps)

    await Timer(2 * bit_ps, unit="ps")
    assert model.frames_in == 600, f"{model.frames_in} of 600 frames arrived"
    assert model.races > 0, "no byte ever landed on the edge of a read"
    dut._log.info(f"{model.frames_in} frames, {model.rx_reads} reads, "
                  f"{model.races} landed on the edge of a read")


@cocotb.test()
async def full_speed(dut):
    """Bytes back to back at the same bit rate as the echo. Polling cannot keep up."""
    model, received, bit_ps = await start(dut, "echo")

    rng = random.Random(19)  # a fixed seed, so the README's numbers can be repeated
    data = [rng.randrange(256) for _ in range(256)]
    for byte in data:
        await send_frame(dut, byte, bit_ps)
    await Timer(40 * bit_ps, unit="ps")

    # Whatever came back must still be in order, with bytes missing but none invented.
    remaining = iter(upper(byte) for byte in data)
    assert all(byte in remaining for byte in received), "the echo is not a subsequence"
    assert model.tx_lost == 0, "a byte was written while the transmitter was busy"
    assert model.overruns > 0, "no byte was ever overwritten"
    dut._log.info(f"CLKS_PER_BIT={int(dut.CLKS_PER_BIT.value)}: {len(data)} bytes back to "
                  f"back, {len(received)} echoed, {model.overruns} overwritten, "
                  f"first at byte {model.first_overrun}")
