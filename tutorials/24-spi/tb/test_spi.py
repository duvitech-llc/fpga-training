import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, First, ReadOnly, Timer, ValueChange
from cocotb.utils import get_sim_time

CLOCK_PS = 10_000


class SpiDevice:
    """An SPI device in any mode. It samples MOSI on its sampling edge, puts the
    next bit on MISO 1 ns after its launching edge, and records every timing or
    protocol problem it sees in self.errors."""

    def __init__(self, dut, rng):
        self.dut = dut
        self.rng = rng
        self.cpol = 0
        self.cpha = 0
        self.half_ps = CLOCK_PS
        self.replies = None  # a list of bytes to answer with, or None for random
        self.received = []   # one list of bytes per transaction
        self.answered = []   # what MISO carried, one list per transaction
        self.errors = []
        self.mosi_moved_at = -1
        dut.miso.value = 0
        cocotb.start_soon(self._watch_mosi())
        cocotb.start_soon(self._run())

    def error(self, what):
        self.errors.append(f"{get_sim_time('ns')} ns: {what}")

    async def _watch_mosi(self):
        while True:
            await ValueChange(self.dut.mosi)
            self.mosi_moved_at = get_sim_time("ps")

    async def _drive(self, bit):
        await Timer(1, unit="ns")
        self.dut.miso.value = bit

    def _next_byte(self, index):
        if self.replies is not None:
            return self.replies[index % len(self.replies)]
        return self.rng.randrange(256)

    async def _run(self):
        dut = self.dut
        while True:
            await FallingEdge(dut.cs_n)
            await ReadOnly()
            if int(dut.sclk.value) != self.cpol:
                self.error("SCLK not at CPOL when CS fell")
            cpol, cpha, half = self.cpol, self.cpha, self.half_ps
            level = int(dut.sclk.value)
            last_edge = get_sim_time("ps")
            edges = 0
            samples = 0
            shift = 0
            got = []
            out = []        # bytes started on MISO
            out_bits = 0    # bits put on MISO so far

            def launch():
                nonlocal out_bits
                if out_bits % 8 == 0:
                    out.append(self._next_byte(len(out)))
                bit = (out[-1] >> (7 - out_bits % 8)) & 1
                out_bits += 1
                cocotb.start_soon(self._drive(bit))

            if cpha == 0:
                launch()  # the first bit goes out before the first edge

            while True:
                await First(ValueChange(dut.sclk), ValueChange(dut.cs_n))
                await ReadOnly()
                now = get_sim_time("ps")
                if int(dut.cs_n.value) == 1:
                    if edges % 16 != 0:
                        self.error(f"CS rose after {edges} edges, not a whole byte")
                    if int(dut.sclk.value) != cpol:
                        self.error("SCLK not at CPOL when CS rose")
                    if edges and now - last_edge != half:
                        self.error(f"CS rose {now - last_edge} ps after the last edge")
                    self.received.append(got)
                    self.answered.append(out[: len(got)])
                    cocotb.start_soon(self._drive(0))
                    break
                if int(dut.sclk.value) == level:
                    continue
                level = int(dut.sclk.value)

                # Half periods: exact inside a byte, at least that between bytes.
                gap = now - last_edge
                if edges % 16 != 0 and gap != half:
                    self.error(f"half period of {gap} ps inside a byte, expected {half}")
                if edges % 16 == 0 and gap < half:
                    self.error(f"only {gap} ps before the first edge of a byte")
                last_edge = now
                edges += 1

                leading = level != cpol
                if leading != bool(cpha):  # this is a sampling edge
                    if self.mosi_moved_at == now:
                        self.error("MOSI moved on a sampling edge")
                    shift = ((shift << 1) | int(dut.mosi.value)) & 0xFF
                    samples += 1
                    if samples % 8 == 0:
                        got.append(shift)
                else:
                    launch()


async def start(dut, seed):
    cocotb.start_soon(Clock(dut.clk, CLOCK_PS, unit="ps").start())
    dut.rst.value = 1
    dut.cpol.value = 0
    dut.cpha.value = 0
    dut.clk_div.value = 0
    dut.tx_valid.value = 0
    dut.tx_data.value = 0
    dut.tx_last.value = 0
    rng = random.Random(seed)
    device = SpiDevice(dut, rng)
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst.value = 0
    received = []
    cocotb.start_soon(collect(dut, received))
    return device, received, rng


async def collect(dut, received):
    while True:
        await FallingEdge(dut.clk)
        if int(dut.rx_valid.value):
            received.append(int(dut.rx_data.value))


async def put(dut, byte, last):
    """Call just after a falling edge. Returns once the byte was accepted."""
    dut.tx_valid.value = 1
    dut.tx_data.value = byte
    dut.tx_last.value = int(last)
    await ReadOnly()
    while not int(dut.tx_ready.value):
        await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.tx_valid.value = 0
    dut.tx_last.value = 0
    dut.tx_data.value = (~byte) & 0xFF


async def wait_idle(dut):
    await ReadOnly()
    while not (int(dut.cs_n.value) and int(dut.tx_ready.value)):
        await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)


async def set_mode(dut, device, master_mode, device_mode, div):
    dut.cpol.value = master_mode >> 1
    dut.cpha.value = master_mode & 1
    dut.clk_div.value = div
    device.cpol = device_mode >> 1
    device.cpha = device_mode & 1
    device.half_ps = (div + 1) * CLOCK_PS


@cocotb.test()
async def random_transactions(dut):
    """Random modes, dividers, lengths, bytes and gaps, against a device in the same mode."""
    device, received, rng = await start(dut, seed=23)
    count = {m: 0 for m in range(4)}
    divs = set()
    held = 0  # times the master waited with CS low for a late byte

    for _ in range(300):
        mode = rng.randrange(4)
        div = rng.choice([0, 0, 1, 2, 3, rng.randrange(4, 40)])
        await set_mode(dut, device, mode, mode, div)
        count[mode] += 1
        divs.add(div)
        data = [rng.randrange(256) for _ in range(rng.randint(1, 5))]
        before = len(received)

        for i, byte in enumerate(data):
            if i and rng.random() < 0.3:
                held += 1
                for _ in range(rng.randrange(1, 4 * (div + 1) + 2)):
                    await FallingEdge(dut.clk)
            await put(dut, byte, i == len(data) - 1)
        await wait_idle(dut)

        assert not device.errors, device.errors[:5]
        assert device.received[-1] == data, f"device got {device.received[-1]} for {data}"
        assert received[before:] == device.answered[-1], (
            f"master got {received[before:]}, device sent {device.answered[-1]}"
        )

    assert all(count.values()) and held > 0 and max(divs) >= 4
    dut._log.info(
        f"{sum(count.values())} transactions, per mode {count}, dividers {min(divs)} "
        f"to {max(divs)}, {held} late bytes with CS held"
    )


@cocotb.test()
async def mode_mismatch(dut):
    """Every master mode against every device mode, to show what a mismatch does."""
    device, received, rng = await start(dut, seed=1)
    device.replies = [0xA5, 0x0F]
    sent = [0x3C, 0x5A]
    lines = []

    for device_mode in range(4):
        for master_mode in range(4):
            await set_mode(dut, device, master_mode, device_mode, 1)
            await wait_idle(dut)
            errors = len(device.errors)
            before = len(received)
            for i, byte in enumerate(sent):
                await put(dut, byte, i == len(sent) - 1)
            await wait_idle(dut)
            got = received[before:]
            dev_got = device.received[-1]
            flagged = len(device.errors) - errors
            ok = got == device.replies and dev_got == sent
            lines.append(
                f"device mode {device_mode}, master mode {master_mode}: "
                f"device got {' '.join(f'{b:02x}' for b in dev_got) or '--':5s}  "
                f"master got {' '.join(f'{b:02x}' for b in got)}  "
                f"problems flagged {flagged}"
            )
            if device_mode == master_mode:
                assert ok and flagged == 0, lines[-1]
            else:
                # A mismatch must be visible: wrong data, or a flagged problem.
                assert not ok or flagged, lines[-1]

    dut._log.info("sent 3c 5a, device answers a5 0f\n" + "\n".join(lines))
