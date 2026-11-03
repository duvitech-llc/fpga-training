import random
from collections import Counter, deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge

CYCLES = 20000
PHASE_CYCLES = 100
# (write rate, read rate). Equal rates stay in the middle, so without the
# phases that favour one side the queue would seldom reach full or empty.
PHASES = [(0.9, 0.2), (0.2, 0.9), (0.9, 0.9), (0.5, 0.5)]
EVENTS = ("write wraps", "read wraps", "became full", "became empty",
          "writes ignored", "reads ignored", "both at full", "both at empty")


@cocotb.test()
async def random_traffic(dut):
    """Compare the FIFO against a Python deque for random writes and reads."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    width = int(dut.WIDTH.value)
    depth = int(dut.DEPTH.value)

    dut.rst.value = 1
    dut.wr_en.value = 0
    dut.wr_data.value = 0
    dut.rd_en.value = 0
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)

    scoreboard = deque()
    events = Counter()
    writes = 0
    reads = 0

    for cycle in range(CYCLES):
        if cycle % PHASE_CYCLES == 0:
            write_rate, read_rate = random.choice(PHASES)

        # Reset is rare, otherwise the queue would seldom fill.
        rst = int(random.random() < 0.002)
        wr_en = int(random.random() < write_rate)
        rd_en = int(random.random() < read_rate)
        wr_data = random.getrandbits(width)
        dut.rst.value = rst
        dut.wr_en.value = wr_en
        dut.wr_data.value = wr_data
        dut.rd_en.value = rd_en

        was_full = len(scoreboard) == depth
        was_empty = len(scoreboard) == 0
        previous = dut.rd_data.value
        expected_read = None

        await FallingEdge(dut.clk)

        if rst:
            scoreboard.clear()
            writes = 0
            reads = 0
        else:
            if rd_en and not was_empty:
                expected_read = scoreboard.popleft()
                reads += 1
                events["read wraps"] += reads % depth == 0
            if wr_en and not was_full:
                scoreboard.append(wr_data)
                writes += 1
                events["write wraps"] += writes % depth == 0
            events["writes ignored"] += wr_en and was_full
            events["reads ignored"] += rd_en and was_empty
            events["both at full"] += wr_en and rd_en and was_full
            events["both at empty"] += wr_en and rd_en and was_empty
            events["became full"] += not was_full and len(scoreboard) == depth
            events["became empty"] += not was_empty and len(scoreboard) == 0

        assert dut.full.value == (len(scoreboard) == depth), f"cycle {cycle}"
        assert dut.empty.value == (len(scoreboard) == 0), f"cycle {cycle}"
        if expected_read is None:
            assert dut.rd_data.value == previous, f"cycle {cycle}: rd_data did not hold"
        else:
            assert dut.rd_data.value == expected_read, f"cycle {cycle}"

    for name in EVENTS:
        assert events[name] > 0, f"the random traffic never reached: {name}"
    dut._log.info(f"WIDTH={width} DEPTH={depth} {dict(events)}")
