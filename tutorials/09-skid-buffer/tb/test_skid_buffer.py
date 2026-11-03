import random
from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge

# Chance per clock of (a new word on offer, m_ready high). Each pair gets equal
# time. They cover a fast and a slow side in both orders, and an even match.
PHASES = [(0.5, 0.5), (1.0, 0.7), (0.3, 0.9), (0.9, 0.3), (1.0, 0.95)]
CLOCKS_PER_PHASE = 2000


@cocotb.test()
async def random_traffic(dut):
    """Check that every word arrives once and in order, whatever the two sides do."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    mask = (1 << int(dut.WIDTH.value)) - 1

    dut.rst.value = 1
    dut.s_valid.value = 0
    dut.s_data.value = 0
    dut.m_ready.value = 0
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)

    inside = deque()       # the scoreboard: words accepted but not yet delivered
    next_word = 0          # words are numbered, so a loss or repeat cannot look right
    offering = False       # upstream is holding a word until it is accepted
    just_reset = True      # s_ready stays low for one clock after reset
    held = None            # the word that must stay on m_data after a stall
    was_ready = False      # m_ready on the previous clock
    was_skid = False
    counts = dict(transfers=0, stalls=0, skid_uses=0, stall_starts_on_transfer=0, resets=0)

    for p_valid, p_ready in PHASES:
        for _ in range(CLOCKS_PER_PHASE):
            # Reset is rare, otherwise the buffer would seldom fill.
            rst = int(random.random() < 0.002)
            if not offering and random.random() < p_valid:
                offering = True
                dut.s_data.value = next_word & mask
            m_ready = int(random.random() < p_ready)
            dut.rst.value = rst
            dut.s_valid.value = int(offering)
            dut.m_ready.value = m_ready

            # The outputs are registered, so they hold still until the rising
            # edge, and these are the values that it will sample.
            s_ready = int(dut.s_ready.value)
            m_valid = int(dut.m_valid.value)
            skid = int(dut.skid_valid.value)

            # The state table: words inside decides both valid and ready.
            assert m_valid == (len(inside) > 0), f"m_valid={m_valid} with {len(inside)} inside"
            assert s_ready == (len(inside) < 2 and not just_reset), (
                f"s_ready={s_ready} with {len(inside)} inside"
            )

            # A stalled word stays, unchanged, until it is accepted.
            if held is not None:
                assert int(dut.m_data.value) == held, "m_data changed during a stall"

            if rst:
                inside.clear()
                offering = False
                just_reset = True
                held = None
                counts["resets"] += 1
            else:
                just_reset = False
                s_xfer = offering and s_ready
                m_xfer = m_valid and m_ready
                stalled = m_valid and not m_ready

                if m_xfer:
                    expected = inside.popleft()
                    got = int(dut.m_data.value)
                    assert got == expected & mask, f"got {got}, expected {expected & mask}"
                    counts["transfers"] += 1
                if s_xfer:
                    inside.append(next_word)
                    next_word += 1
                    offering = False

                held = int(dut.m_data.value) if stalled else None
                counts["stalls"] += stalled
                counts["stall_starts_on_transfer"] += stalled and s_xfer and was_ready
                counts["skid_uses"] += skid and not was_skid

            was_ready = bool(m_ready)
            was_skid = bool(skid)
            await FallingEdge(dut.clk)

    # Drain, so that a word lost near the end is noticed too.
    dut.rst.value = 0
    dut.s_valid.value = 0
    dut.m_ready.value = 1
    for _ in range(4):
        if int(dut.m_valid.value):
            expected = inside.popleft()
            assert int(dut.m_data.value) == expected & mask, "wrong word during the drain"
            counts["transfers"] += 1
        await FallingEdge(dut.clk)
    assert not inside, f"{len(inside)} words never arrived"
    assert not int(dut.m_valid.value), "a word came out that was never accepted"

    # A random test can pass by never reaching the interesting cases.
    for name, value in counts.items():
        assert value > 0, f"the random inputs never produced any {name}"
    dut._log.info(" ".join(f"{name}={value}" for name, value in counts.items()))
