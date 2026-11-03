import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer


@cocotb.test()
async def random_inputs(dut):
    """Compare both read ports and every register against a Python list."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    width = int(dut.WIDTH.value)
    regs = int(dut.REGS.value)
    slots = 1 << len(dut.waddr)  # includes addresses with no register

    dut.rst.value = 1
    dut.we.value = 0
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    model = [0] * regs

    def expected(addr):
        return model[addr] if addr < regs else 0

    old_reads = 0
    two_values = 0
    reset_clears = 0
    bad_writes = 0
    bad_reads = 0

    for _ in range(10000):
        # Reset is rare, otherwise the registers would seldom hold anything.
        rst = int(random.random() < 0.01)
        we = int(random.random() < 0.6)
        waddr = random.randrange(slots)
        wdata = random.getrandbits(width)
        raddr_a = random.randrange(slots)
        raddr_b = random.randrange(slots)
        # Aim some reads at the write address.
        if random.random() < 0.3:
            raddr_a = waddr
        if random.random() < 0.3:
            raddr_b = waddr

        dut.rst.value = rst
        dut.we.value = we
        dut.waddr.value = waddr
        dut.wdata.value = wdata
        dut.raddr_a.value = raddr_a
        dut.raddr_b.value = raddr_b

        # Before the rising edge the reads must show the old values.
        await Timer(1, unit="ns")
        assert dut.rdata_a.value == expected(raddr_a), f"before edge, raddr_a={raddr_a}"
        assert dut.rdata_b.value == expected(raddr_b), f"before edge, raddr_b={raddr_b}"

        # Count the cases that a run could otherwise miss.
        writing = we and not rst and waddr < regs and wdata != model[waddr]
        old_reads += writing and raddr_a == waddr
        old_reads += writing and raddr_b == waddr
        two_values += expected(raddr_a) != expected(raddr_b)
        reset_clears += rst and any(model)
        bad_writes += we and not rst and waddr >= regs
        bad_reads += raddr_a >= regs
        bad_reads += raddr_b >= regs

        await FallingEdge(dut.clk)

        if rst:
            model = [0] * regs
        elif we and waddr < regs:
            model[waddr] = wdata

        assert dut.rdata_a.value == expected(raddr_a), f"after edge, raddr_a={raddr_a}"
        assert dut.rdata_b.value == expected(raddr_b), f"after edge, raddr_b={raddr_b}"

        # A write that lands in a second register may not be read for a while,
        # so look at each register directly, through the hierarchy.
        for i in range(regs):
            value = dut.gen_regs[i].u_reg.q.value
            assert value == model[i], f"register {i} rst={rst} we={we} waddr={waddr}"

    assert old_reads > 0, "no read landed on a write of new data"
    assert two_values > 0, "the two ports never showed two different values"
    assert reset_clears > 0, "no reset hit a register holding data"
    if slots > regs:
        assert bad_writes > 0, "no write used an address with no register"
        assert bad_reads > 0, "no read used an address with no register"
    dut._log.info(
        f"REGS={regs}: {old_reads} old-value reads, {two_values} two-value reads, "
        f"{reset_clears} resets, {bad_writes} bad writes, {bad_reads} bad reads"
    )
