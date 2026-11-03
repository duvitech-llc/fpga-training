import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly

OKAY, SLVERR, DECERR = 0, 2, 3
ID = 0x4158494C

# Each phase: (most clocks before each new valid, percent of clocks with each
# slave ready held low, percent of clocks with bready and rready low).
PHASES = [(0, 0, 0), (3, 30, 30), (1, 60, 10), (5, 10, 60), (2, 50, 50)]
CLOCKS_PER_PHASE = 2000

# Writes and reads go to these addresses. ID and the unmapped ones give errors.
ADDRESSES = [0x0, 0x4, 0x8, 0xC, 0x10, 0x14, 0x1C, 0x1000, 0x80000000, 0x5, 0xA]


def expected_resp(addr, write):
    if addr >> 5 != 0 or (addr >> 2) & 7 > 4:
        return DECERR
    if (addr >> 2) & 4:
        return SLVERR if write else OKAY
    return OKAY


def merge(old, data, strb):
    for k in range(4):
        if strb >> k & 1:
            mask = 0xFF << (8 * k)
            old = (old & ~mask) | (data & mask)
    return old


@cocotb.test()
async def random_traffic(dut):
    """Random writes and reads, with random backpressure and a random order of AW and W."""
    buffered = int(dut.BUFFERED.value)
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    for name in ("awvalid", "wvalid", "arvalid", "bready", "rready",
                 "awaddr", "awprot", "wdata", "wstrb", "araddr", "arprot", "hold"):
        getattr(dut, name).value = 0
    dut.rst.value = 1
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst.value = 0

    model = [0, 0, 0, 0]  # the registers, updated when a write's response is taken
    writes = []           # every write so far: dict(addr, data, strb, aw, w, b)
    reads = []            # every read so far: dict(addr, expect or None)
    aw_i = w_i = b_i = 0  # the write each channel is on
    ar_i = r_i = 0
    aw_wait = w_wait = ar_wait = 0
    b_held = r_held = None  # a response that was not taken, which must not change
    aw_on = w_on = ar_on = False  # what awvalid, wvalid and arvalid are set to
    counts = dict(writes=0, reads=0, checked_reads=0, partial_writes=0, slverr=0, decerr=0,
                  w_first=0, aw_first=0, same_clock=0, ready_held=0, b_stalls=0, r_stalls=0)
    clock = 0

    def new_write():
        writes.append(dict(addr=random.choice(ADDRESSES), data=random.getrandbits(32),
                           strb=random.getrandbits(4), aw=None, w=None, b=False,
                           aw_offer=None, w_offer=None))

    for max_delay, p_hold, p_busy in PHASES:
        rates = [clock, b_i + r_i]
        for _ in range(CLOCKS_PER_PHASE):
            # Offer the next item on each request channel, after a random delay.
            # valid never waits for ready, and a valid that is up stays up.
            if not aw_on:
                if aw_wait:
                    aw_wait -= 1
                else:
                    while len(writes) <= aw_i:
                        new_write()
                    dut.awvalid.value = 1
                    aw_on = True
                    dut.awaddr.value = writes[aw_i]["addr"]
                    dut.awprot.value = random.getrandbits(3)
                    writes[aw_i]["aw_offer"] = clock
            if not w_on:
                if w_wait:
                    w_wait -= 1
                else:
                    while len(writes) <= w_i:
                        new_write()
                    dut.wvalid.value = 1
                    w_on = True
                    dut.wdata.value = writes[w_i]["data"]
                    dut.wstrb.value = writes[w_i]["strb"]
                    writes[w_i]["w_offer"] = clock
            if not ar_on:
                if ar_wait:
                    ar_wait -= 1
                else:
                    while len(reads) <= ar_i:
                        reads.append(dict(addr=random.choice(ADDRESSES), expect=None))
                    dut.arvalid.value = 1
                    ar_on = True
                    dut.araddr.value = reads[ar_i]["addr"]
                    dut.arprot.value = random.getrandbits(3)

            hold = sum((random.randrange(100) < p_hold) << k for k in range(3))
            dut.hold.value = hold
            bready = int(random.randrange(100) >= p_busy)
            rready = int(random.randrange(100) >= p_busy)
            dut.bready.value = bready
            dut.rready.value = rready
            counts["ready_held"] += hold != 0

            # The waiting slave's readys depend on the valids, so let them settle.
            await ReadOnly()
            aw_hs = aw_on and int(dut.awready.value)
            w_hs = w_on and int(dut.wready.value)
            ar_hs = ar_on and int(dut.arready.value)
            bvalid = int(dut.bvalid.value)
            rvalid = int(dut.rvalid.value)

            # A response that was not taken must still be there, unchanged.
            if b_held is not None:
                assert bvalid and int(dut.bresp.value) == b_held, "B changed before it was taken"
            if r_held is not None:
                assert rvalid and (int(dut.rdata.value), int(dut.rresp.value)) == r_held, \
                    "R changed before it was taken"
            b_held = int(dut.bresp.value) if bvalid and not bready else None
            r_held = (int(dut.rdata.value), int(dut.rresp.value)) if rvalid and not rready else None
            counts["b_stalls"] += bvalid and not bready
            counts["r_stalls"] += rvalid and not rready

            # Responses first: a write answered at this edge is already done.
            if bvalid and bready:
                wr = writes[b_i]
                assert wr["aw"] is not None and wr["w"] is not None, \
                    "a write response came before its AW and W were taken"
                resp = int(dut.bresp.value)
                assert resp == expected_resp(wr["addr"], True), \
                    f"write {wr['addr']:#x}: bresp={resp}"
                if resp == OKAY:
                    reg = (wr["addr"] >> 2) & 3
                    model[reg] = merge(model[reg], wr["data"], wr["strb"])
                    counts["partial_writes"] += wr["strb"] not in (0, 0xF)
                counts["slverr"] += resp == SLVERR
                counts["decerr"] += resp == DECERR
                wr["b"] = True
                b_i += 1
                counts["writes"] += 1
            if rvalid and rready:
                assert r_i < ar_i, "a read response came before its request"
                rd = reads[r_i]
                resp = int(dut.rresp.value)
                assert resp == expected_resp(rd["addr"], False), f"read {rd['addr']:#x}: rresp={resp}"
                if resp == DECERR:
                    assert int(dut.rdata.value) == 0, "DECERR with data"
                if rd["expect"] is not None:
                    got = int(dut.rdata.value)
                    assert got == rd["expect"], \
                        f"read {rd['addr']:#x}: got {got:#010x}, expected {rd['expect']:#010x}"
                    counts["checked_reads"] += 1
                r_i += 1
                counts["reads"] += 1

            # Requests taken at this edge.
            if ar_hs:
                rd = reads[ar_i]
                addr = rd["addr"]
                if expected_resp(addr, False) == OKAY:
                    if (addr >> 2) & 4:
                        rd["expect"] = ID
                    else:
                        reg = (addr >> 2) & 3
                        # A write to the same register with a half already taken
                        # may or may not be done yet, so this read proves nothing.
                        busy = any(not wr["b"] and (wr["aw"] is not None or wr["w"] is not None)
                                   and expected_resp(wr["addr"], True) == OKAY
                                   and (wr["addr"] >> 2) & 3 == reg
                                   for wr in writes[b_i:])
                        if not busy:
                            rd["expect"] = model[reg]
                ar_i += 1
                ar_wait = random.randint(0, max_delay)
            if aw_hs:
                writes[aw_i]["aw"] = clock
                aw_i += 1
                aw_wait = random.randint(0, max_delay)
            if w_hs:
                writes[w_i]["w"] = clock
                w_i += 1
                w_wait = random.randint(0, max_delay)

            await FallingEdge(dut.clk)
            clock += 1
            # What the edge took is no longer on offer, unless the next item
            # replaces it straight away, below.
            if aw_hs:
                dut.awvalid.value = 0
                aw_on = False
            if w_hs:
                dut.wvalid.value = 0
                w_on = False
            if ar_hs:
                dut.arvalid.value = 0
                ar_on = False

        done = b_i + r_i - rates[1]
        dut._log.info(f"phase delay<={max_delay} hold={p_hold}% busy={p_busy}%: "
                      f"{done} transactions in {CLOCKS_PER_PHASE} clocks, "
                      f"{done / CLOCKS_PER_PHASE:.2f} per clock")

    # Let the last writes to the inputs land before the test ends. Without this,
    # the simulator in this release often crashed after the test had passed.
    await FallingEdge(dut.clk)

    # The order in which the two halves of each finished write were offered.
    for wr in writes[:b_i]:
        if wr["w_offer"] < wr["aw_offer"]:
            counts["w_first"] += 1
        elif wr["aw_offer"] < wr["w_offer"]:
            counts["aw_first"] += 1
        else:
            counts["same_clock"] += 1
        if buffered:
            assert wr["aw"] is not None and wr["w"] is not None
        else:
            assert wr["aw"] == wr["w"], "the waiting slave took AW and W at different edges"

    # A random test can pass by never reaching the interesting cases.
    for name, value in counts.items():
        assert value > 0, f"the random inputs never produced any {name}"
    dut._log.info(" ".join(f"{name}={value}" for name, value in counts.items()))
