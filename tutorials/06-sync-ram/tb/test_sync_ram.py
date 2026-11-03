import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer


@cocotb.test()
async def random_traffic(dut):
    """Compare rdata against a Python model of the memory for random reads and writes."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    width = int(dut.WIDTH.value)
    depth = int(dut.DEPTH.value)

    dut.we.value = 0
    dut.waddr.value = 0
    dut.wdata.value = 0
    dut.re.value = 0
    dut.raddr.value = 0
    await FallingEdge(dut.clk)

    model = {}  # address to last value written, a missing address is unknown
    # What rdata shows until the next read, x bits included, so the hold checks
    # also run after a read of a word that was never written.
    held = dut.rdata.value
    collisions = 0
    unwritten_reads = 0

    for _ in range(10000):
        we = int(random.random() < 0.5)
        waddr = random.randrange(depth)
        wdata = random.getrandbits(width)
        re = int(random.random() < 0.7)
        # Random addresses seldom match, so aim many reads at the write address.
        raddr = waddr if random.random() < 0.3 else random.randrange(depth)
        dut.we.value = we
        dut.waddr.value = waddr
        dut.wdata.value = wdata
        dut.re.value = re
        dut.raddr.value = raddr

        # No read can show up before the rising edge.
        await Timer(1, unit="ns")
        assert str(dut.rdata.value) == str(held), f"rdata moved early, raddr={raddr}"

        await FallingEdge(dut.clk)

        if re:
            expected = model.get(raddr)
            if expected is None:
                unwritten_reads += 1
                assert not dut.rdata.value.is_resolvable, f"raddr={raddr} was never written"
            else:
                assert dut.rdata.value == expected, f"raddr={raddr}"
                collisions += we and raddr == waddr and wdata != expected
            held = dut.rdata.value
        else:
            assert str(dut.rdata.value) == str(held), "rdata changed with re low"

        # Update after the check: a read during a write sees the old data.
        if we:
            model[waddr] = wdata

    assert collisions > 0, "no read ever landed on a write of new data"
    dut._log.info(
        f"WIDTH={width} DEPTH={depth} wrote {len(model)} words, "
        f"{collisions} reads during a write, {unwritten_reads} unwritten reads"
    )
