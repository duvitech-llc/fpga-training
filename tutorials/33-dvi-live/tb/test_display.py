"""cocotb test of rtl/wb_display.v alone: a queued frame reads the buffer it was
given.

When the reader is still busy with one frame as the next vertical blank comes,
it queues the new frame and starts it later. CURRENT takes BASE at that blank,
and the queued frame must read from there, even if the program has written
BASE again since. The whole system never makes that happen: its program swaps
buffers long after a queued frame has started. So this test makes it happen,
with the reader's bus stalled across a blank.

Inputs change on the falling edge. The framebuffer is a model here: it takes a
request when m_stall is low and answers it on the next clock.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge

# Set from the Makefile: a small frame, so a frame is a few bursts.
WIDTH, HEIGHT = 16, 2
WORDS = WIDTH * HEIGHT // 4

R_CTRL, R_BASE, R_CURRENT = 0, 1, 2
BUF_A, BUF_B, BUF_C = 0x0100_0000, 0x0100_4000, 0x0100_8000


class Bus:
    """The framebuffer, as seen by the reader, and the slave port's master."""

    def __init__(self, dut):
        self.dut = dut
        self.stalled = True
        self.taken = []           # word addresses of the requests taken
        self.ack_next = False

    async def clock(self):
        """One clock. Call on a falling edge; returns on the next one."""
        dut = self.dut
        dut.m_ack.value = int(self.ack_next)
        dut.m_stall.value = int(self.stalled)
        dut.m_dat_r.value = 0
        # The request presented now is taken at the next rising edge if not stalled.
        take = (dut.m_cyc.value == 1 and dut.m_stb.value == 1 and not self.stalled)
        if take:
            self.taken.append(int(dut.m_adr.value))
        self.ack_next = take
        await FallingEdge(dut.clk)

    async def clocks(self, n):
        for _ in range(n):
            await self.clock()

    async def access(self, adr, we, data=0):
        """One request on the slave port; returns the read data."""
        dut = self.dut
        dut.cyc.value = 1
        dut.stb.value = 1
        dut.we.value = int(we)
        dut.adr.value = adr
        dut.sel.value = 0xF
        dut.dat_w.value = data
        await self.clock()                 # taken: stall is low, hold is 0
        dut.stb.value = 0
        while dut.ack.value != 1:
            await self.clock()
        value = int(dut.dat_r.value)
        dut.cyc.value = 0
        dut.we.value = 0
        await self.clock()
        return value

    async def blank(self):
        """Vertical blanking: the level rises, holds, then falls."""
        self.dut.vblank_p.value = 1
        await self.clocks(8)
        self.dut.vblank_p.value = 0
        await self.clocks(4)


@cocotb.test()
async def queued_frame_reads_its_own_buffer(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    for name in ("cyc", "stb", "we", "adr", "sel", "dat_w", "hold", "m_ack", "m_err",
                 "m_dat_r", "fifo_used", "vblank_p", "underrun_p"):
        getattr(dut, name).value = 0
    dut.m_stall.value = 1
    dut.show_p.value = 1                   # every frame is shown
    dut.rst.value = 1
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst.value = 0
    bus = Bus(dut)
    await bus.clocks(4)

    await bus.access(R_CTRL, True, 1)
    await bus.access(R_BASE, True, BUF_A)

    # Frame 1 starts from A, and the framebuffer stalls it.
    await bus.blank()
    # The program swaps to B, and the next blank comes while frame 1 still waits:
    # frame 2 is queued, and CURRENT takes B.
    await bus.access(R_BASE, True, BUF_B)
    await bus.blank()
    current = await bus.access(R_CURRENT, False)
    assert current == BUF_B, f"CURRENT is {current:#x} after the second blank, not {BUF_B:#x}"
    # Then the program writes BASE again, before frame 2 has started.
    await bus.access(R_BASE, True, BUF_C)
    assert bus.taken == [], f"requests were taken while the bus stalled: {bus.taken}"

    # The stall ends. Frame 1, then the queued frame 2.
    bus.stalled = False
    for _ in range(40 * WORDS):
        await bus.clock()
        if len(bus.taken) >= 2 * WORDS:
            break
    await bus.clocks(4)

    want = ([BUF_A // 4 + k for k in range(WORDS)] +
            [BUF_B // 4 + k for k in range(WORDS)])
    got = bus.taken
    dut._log.info("frame 1 read from %#x, frame 2 from %#x, %d requests",
                  got[0] * 4 if got else 0, got[WORDS] * 4 if len(got) > WORDS else 0,
                  len(got))
    assert len(got) == 2 * WORDS, f"{len(got)} requests, not {2 * WORDS}"
    for k, (g, w) in enumerate(zip(got, want)):
        assert g == w, (f"request {k} read word address {g:#x}, not {w:#x}: frame "
                        f"{1 + k // WORDS} read the wrong buffer")
    await bus.clock()                      # one clock after the last input write
