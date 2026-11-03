import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer


class Requesters:
    """Random traffic: a request is held until granted, and each wait is measured."""

    def __init__(self, n):
        self.n = n
        self.req = 0
        self.waiting = [0] * n
        self.max_wait = [0] * n

    def new_requests(self, load):
        for i in range(self.n):
            if random.random() < load:
                self.req |= 1 << i

    def update(self, grant, rst=0):
        for i in range(self.n):
            if rst:  # reset restarts the round, so every wait restarts too
                self.waiting[i] = 0
            elif grant >> i & 1:
                self.waiting[i] = 0
                self.req &= ~(1 << i)
            elif self.req >> i & 1:
                self.waiting[i] += 1
                # Recorded here so that a request that never gets a grant counts.
                self.max_wait[i] = max(self.max_wait[i], self.waiting[i])


@cocotb.test()
async def random_load(dut):
    """Check every grant, and measure the longest wait of each requester."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    n = int(dut.N.value)
    rr = Requesters(n)
    fixed = Requesters(n)  # equally heavy traffic for a Python fixed-priority arbiter

    dut.rst.value = 1
    dut.req.value = 0
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)

    grants = [0] * n
    contended = 0
    wraps = 0
    last = None

    # A light, a medium and a heavy load. Under the heavy load a requester often
    # asks again straight after its grant, which is how a winner can hog the bus.
    for load in (0.05, 0.3, 0.9):
        for _ in range(2000):
            # Reset is rare, otherwise the mask would seldom get far.
            rst = int(random.random() < 0.002)
            rr.new_requests(load)
            fixed.new_requests(load)
            dut.rst.value = rst
            dut.req.value = rr.req

            # grant is combinational, so it can be checked before the rising edge.
            await Timer(1, unit="ns")
            grant = int(dut.grant.value)
            context = f"rst={rst} req={rr.req:0{n}b} grant={grant:0{n}b}"

            assert grant & (grant - 1) == 0, f"grant is not one-hot: {context}"
            assert grant & ~rr.req == 0, f"grant without a request: {context}"
            if rst:
                assert grant == 0, f"grant during reset: {context}"
            elif rr.req:
                assert grant != 0, f"no grant for a request: {context}"

            contended += bin(rr.req).count("1") > 1
            if grant:
                index = grant.bit_length() - 1
                grants[index] += 1
                wraps += last is not None and index <= last
                last = index

            if rst:
                last = None
            rr.update(grant, rst)
            assert max(rr.waiting) <= n - 1, f"waited more than N-1 cycles: {context}"

            # req & -req in Python, for comparison only.
            fixed.update(fixed.req & -fixed.req)

            await FallingEdge(dut.clk)

    # A pass means little if the interesting cases never happened.
    assert all(grants), f"a requester was never granted: {grants}"
    assert contended > 0, "no two requests ever competed"
    assert wraps > 0, "the round never wrapped"
    assert max(rr.max_wait) == n - 1, "no request ever waited the full N-1"
    assert max(fixed.max_wait) > n - 1, "this traffic did not stress fixed priority"

    dut._log.info(f"N={n} grants {grants}, {contended} contended cycles, {wraps} wraps")
    dut._log.info(f"N={n} max wait, round-robin:      {rr.max_wait}")
    dut._log.info(f"N={n} max wait, fixed (Python):   {fixed.max_wait}")
