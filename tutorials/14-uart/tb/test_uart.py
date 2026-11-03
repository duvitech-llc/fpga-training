import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, First, ReadOnly, RisingEdge, Timer

CLOCK_PS = 10_000

# The timing error the random test applies. Each frame gets its own bit period,
# and each edge in it moves a little more. The sweep below shows the real limit.
MAX_SKEW = 0.02
MAX_JITTER = 0.02


async def start(dut):
    """Start the clock, reset the design and return the results list."""
    cocotb.start_soon(Clock(dut.clk, CLOCK_PS, unit="ps").start())
    dut.tx_valid.value = 0
    dut.tx_data.value = 0
    dut.rx.value = 1
    await reset(dut)
    results = []
    cocotb.start_soon(monitor(dut, results))
    return results


async def reset(dut):
    dut.rst.value = 1
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst.value = 0


async def monitor(dut, results):
    """Record each byte received, or None for each framing error."""
    while True:
        await First(RisingEdge(dut.rx_valid), RisingEdge(dut.rx_error))
        await ReadOnly()
        results.append(None if int(dut.rx_error.value) else int(dut.rx_data.value))


async def send_frame(dut, byte, bit_ps, jitter_ps=0.0, stop=1, rng=random):
    """Drive one 8N1 frame. This is the model of a sender with its own clock."""
    bits = [0] + [(byte >> i) & 1 for i in range(8)] + [stop]
    now = 0
    for i, level in enumerate(bits):
        dut.rx.value = level
        # Edges are placed from the start of the frame, so rounding to whole
        # picoseconds does not add up over the ten bits.
        edge = round((i + 1) * bit_ps + rng.uniform(-jitter_ps, jitter_ps))
        await Timer(edge - now, unit="ps")
        now = edge
    dut.rx.value = 1


@cocotb.test()
async def random_frames(dut):
    """Random bytes, gaps, timing errors and bad stop bits into the receiver."""
    results = await start(dut)
    nominal = int(dut.CLKS_PER_BIT.value) * CLOCK_PS

    expected = []
    back_to_back = 0
    framing_errors = 0
    glitches = 0
    largest_skew = 0.0
    bad_stop = False

    for _ in range(2000):
        byte = random.randrange(256)
        skew = random.uniform(-MAX_SKEW, MAX_SKEW)
        largest_skew = max(largest_skew, abs(skew))
        bit_ps = nominal * (1 + skew)

        # After a bad stop bit the line must rise before the next start edge.
        if bad_stop or random.random() < 0.6:
            gap_bits = random.uniform(1, 3)
            await Timer(round(gap_bits * bit_ps), unit="ps")
            # Noise: a low pulse too short to reach the middle of a start bit.
            if random.random() < 0.2:
                glitches += 1
                dut.rx.value = 0
                await Timer(round(0.25 * nominal), unit="ps")
                dut.rx.value = 1
                await Timer(nominal, unit="ps")
        else:
            back_to_back += 1

        bad_stop = random.random() < 0.05
        framing_errors += bad_stop
        expected.append(None if bad_stop else byte)
        await send_frame(dut, byte, bit_ps, MAX_JITTER * nominal, stop=int(not bad_stop))

    await Timer(2 * nominal, unit="ps")

    assert len(results) == len(expected), f"{len(results)} results for {len(expected)} frames"
    for i, (got, want) in enumerate(zip(results, expected)):
        assert got == want, f"frame {i}: got {got} expected {want}"

    assert framing_errors > 0, "no frame had a bad stop bit"
    assert back_to_back > 0, "no two frames were back to back"
    assert glitches > 0, "no noise pulse was sent"
    assert largest_skew > MAX_SKEW / 2, "the timing error was never large"
    dut._log.info(
        f"CLKS_PER_BIT={int(dut.CLKS_PER_BIT.value)}: {len(expected)} frames, "
        f"{framing_errors} framing errors, {back_to_back} back to back, "
        f"{glitches} noise pulses, largest skew {100 * largest_skew:.2f}%"
    )


async def frame_lengths(dut, lengths):
    """Record how many clocks tx_ready stays low for each frame."""
    clocks = 0
    busy = False
    while True:
        await RisingEdge(dut.clk)
        await ReadOnly()
        if busy:
            clocks += 1
        if not int(dut.tx_ready.value) and not busy:
            busy, clocks = True, 0
        elif int(dut.tx_ready.value) and busy:
            busy = False
            lengths.append(clocks)


@cocotb.test()
async def random_transmit(dut):
    """Random bytes and gaps into the transmitter, decoded from the line in Python."""
    await start(dut)
    clocks_per_bit = int(dut.CLKS_PER_BIT.value)
    bytes_seen = 0
    waits = 0
    # A frame is ten bits, and the line must not be freed early, even when the
    # next byte is already waiting. The stop bit is the one most easily cut short.
    lengths = []
    cocotb.start_soon(frame_lengths(dut, lengths))

    for _ in range(200):
        byte = random.randrange(256)
        dut.tx_valid.value = 1
        dut.tx_data.value = byte
        # tx_ready only changes on rising edges, so if it is high now, the next
        # rising edge takes the byte. Drop tx_valid on the falling edge after it.
        while not int(dut.tx_ready.value):
            waits += 1
            await FallingEdge(dut.clk)
        await FallingEdge(dut.clk)
        dut.tx_valid.value = 0
        dut.tx_data.value = random.randrange(256)

        # Now half a clock into the frame. Read each bit half way through it.
        for _ in range(clocks_per_bit // 2):
            await FallingEdge(dut.clk)
        line = []
        for bit in range(10):
            line.append(int(dut.tx.value))
            assert not int(dut.tx_ready.value), "tx_ready is high during a frame"
            if bit < 9:
                for _ in range(clocks_per_bit):
                    await FallingEdge(dut.clk)
        want = [0] + [(byte >> i) & 1 for i in range(8)] + [1]
        assert line == want, f"byte {byte:#04x}: line {line}"
        bytes_seen += 1

        # Now half way through the stop bit. Sometimes offer the next byte
        # straight away, so that it has to wait for tx_ready.
        if random.random() < 0.3:
            continue
        for _ in range(clocks_per_bit - clocks_per_bit // 2):
            await FallingEdge(dut.clk)
        for _ in range(random.choice([0, 0, 1, random.randrange(40)])):
            await FallingEdge(dut.clk)

    assert bytes_seen == 200
    assert waits > 0, "no byte ever waited for tx_ready"
    assert len(lengths) >= 199, f"only {len(lengths)} frames finished"
    assert set(lengths) == {10 * clocks_per_bit}, f"frame lengths {sorted(set(lengths))}"
    dut._log.info(f"decoded {bytes_seen} bytes from the tx line, {waits} waits for tx_ready")


@cocotb.test()
async def clock_tolerance(dut):
    """Sweep the sender's bit period and find where the receiver starts to fail."""
    results = await start(dut)
    clocks_per_bit = int(dut.CLKS_PER_BIT.value)
    nominal = clocks_per_bit * CLOCK_PS
    # A fixed seed, so the limits in the lesson can be reproduced.
    rng = random.Random(14)
    count = 128 if clocks_per_bit <= 32 else 32

    failures = {}
    for tenths in range(-80, 81):
        skew = tenths / 1000
        bit_ps = nominal * (1 + skew)
        data = [rng.randrange(256) for _ in range(count)]

        # A random phase, then a stream of back-to-back frames.
        await Timer(rng.randrange(1, CLOCK_PS), unit="ps")
        for byte in data:
            await send_frame(dut, byte, bit_ps)
        await Timer(2 * nominal, unit="ps")

        bad = sum(got != want for got, want in zip(results, data))
        bad += abs(len(results) - len(data))
        if bad:
            failures[tenths] = bad
        if tenths % 10 == 0:
            dut._log.info(f"sender {100 * skew:+.1f}%: {bad} bad of {count}")

        # A failed stream can leave the receiver in the middle of a false frame.
        await reset(dut)
        await Timer(12 * nominal, unit="ps")
        results.clear()

    fast = [t for t in failures if t < 0]
    slow = [t for t in failures if t > 0]
    fast_limit = f"{max(fast) / 10:+.1f}%" if fast else "none"
    slow_limit = f"{min(slow) / 10:+.1f}%" if slow else "none"
    dut._log.info(
        f"CLKS_PER_BIT={clocks_per_bit}: first failure at {fast_limit} (sender fast) "
        f"and {slow_limit} (sender slow)"
    )
    assert fast and slow, "the sweep never reached a failure, so it proves nothing"
    assert not any(abs(t) <= 1000 * MAX_SKEW for t in failures), "failed inside the tolerance"
