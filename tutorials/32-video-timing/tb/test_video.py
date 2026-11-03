import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge

from png import write_png

BUILD = os.path.join(os.path.dirname(__file__), "..", "build")

WHITE = (255, 255, 255)
BLACK = (0, 0, 0)
GREY = (0x40, 0x40, 0x40)
BARS = [
    ("white", WHITE),
    ("yellow", (255, 255, 0)),
    ("cyan", (0, 255, 255)),
    ("green", (0, 255, 0)),
    ("magenta", (255, 0, 255)),
    ("red", (255, 0, 0)),
    ("blue", (0, 0, 255)),
    ("black", BLACK),
]


class Grabber:
    """Builds whole frames from de, frame_start and the colour on each clock."""

    def __init__(self, width, height):
        self.width = width
        self.height = height
        self.frames = []
        self.rows = None    # the frame being captured, or None between frames
        self.de_was = 0

    def clock(self, de, frame_start, pixel):
        if frame_start:
            assert self.rows is None, "frame_start before the last frame was complete"
            assert de and not self.de_was, "frame_start is not on the first pixel of a line"
            self.rows = []
        if self.rows is not None:
            if de and not self.de_was:
                self.rows.append([])
            if de:
                self.rows[-1].append(pixel)
            if not de and self.de_was:
                assert len(self.rows[-1]) == self.width, f"line of {len(self.rows[-1])} pixels"
                if len(self.rows) == self.height:
                    self.frames.append(self.rows)
                    self.rows = None
        self.de_was = de


def model(width, height, box, step, frames):
    """The picture each frame should show, worked out a different way from the RTL."""
    bar_h = height * 3 // 4
    box_y = bar_h + (height - bar_h - box) // 2
    box_x = 0
    out = []
    for _ in range(frames):
        rows = []
        for y in range(height):
            row = []
            for x in range(width):
                if x in (0, width - 1) or y in (0, height - 1):
                    row.append(WHITE)
                elif box_x <= x < box_x + box and box_y <= y < box_y + box:
                    row.append(WHITE)
                elif y < bar_h:
                    row.append(BARS[x * 8 // width][1])
                else:
                    row.append(GREY)
            rows.append(row)
        out.append((box_x, rows))
        # Move right, and back to the left edge if the box would not fit.
        box_x += step
        if box_x + box > width:
            box_x = 0
    return out


def differences(got, expected):
    return [
        (x, y, got[y][x], expected[y][x])
        for y in range(len(expected))
        for x in range(len(expected[0]))
        if got[y][x] != expected[y][x]
    ]


@cocotb.test()
async def frames_to_png(dut):
    """Capture whole frames, write them as PNG files and compare every pixel."""
    mode = os.environ.get("MODE", "small")
    n_frames = int(os.environ.get("FRAMES", "2"))
    width = int(dut.H_ACTIVE.value)
    height = int(dut.V_ACTIVE.value)
    box = int(dut.BOX.value)
    step = int(dut.STEP.value)
    scale = 1 if width >= 320 else 8

    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    dut.rst.value = 1
    for _ in range(3):
        await FallingEdge(dut.clk)
    dut.rst.value = 0

    # Two grabbers on the same clocks. The first uses the pattern's own outputs.
    # The second takes de and frame_start straight from the timing generator,
    # one clock before the colour that goes with them.
    aligned = Grabber(width, height)
    early = Grabber(width, height)
    timing = dut.timing
    clocks = 0
    while len(aligned.frames) < n_frames:
        await FallingEdge(dut.clk)
        clocks += 1
        pixel = (int(dut.r.value), int(dut.g.value), int(dut.b.value))
        aligned.clock(int(dut.de.value), int(dut.frame_start.value), pixel)
        early.clock(int(timing.de.value), int(timing.frame_start.value), pixel)
    dut._log.info(f"{mode}: {n_frames} frames of {width}x{height} in {clocks} clocks")

    expected = model(width, height, box, step, n_frames)

    for n, rows in enumerate(aligned.frames):
        write_png(os.path.join(BUILD, f"frame_{mode}_{n}.png"), rows, scale)
        box_x, want = expected[n]
        bad = differences(rows, want)
        assert not bad, f"frame {n}: {len(bad)} pixels wrong, first {bad[:3]} (x, y, got, expected)"
        dut._log.info(f"frame {n}: all {width * height} pixels match, box at x={box_x}")

    # The bars by name, from the middle of each one, halfway down the bars.
    rows = aligned.frames[0]
    y = height * 3 // 8
    for i, (name, colour) in enumerate(BARS):
        x = (2 * i + 1) * width // 16
        assert rows[y][x] == colour, f"bar {i} at x={x}: got {rows[y][x]}, expected {name} {colour}"
    dut._log.info("bars: " + ", ".join(f"{name} {rows[y][(2 * i + 1) * width // 16]}"
                                       for i, (name, _) in enumerate(BARS)))

    # The box must move on every frame, and in a long enough run it must wrap.
    positions = [box_x for box_x, _ in expected]
    assert all(a != b for a, b in zip(positions, positions[1:])), "the box did not move"
    if n_frames * step > width:
        assert any(b < a for a, b in zip(positions, positions[1:])), "the box never wrapped"

    # The frame seen with de one clock early: every pixel is the one to its left.
    wrong = early.frames[0]
    write_png(os.path.join(BUILD, f"frame_{mode}_misaligned.png"), wrong, scale)
    for y in range(height):
        assert wrong[y][0] == BLACK, f"column 0 of row {y} is {wrong[y][0]}"
        assert wrong[y][1:] == rows[y][:-1], f"row {y} is not shifted by one pixel"
    bad = differences(wrong, expected[0][1])
    right_edge = sum(1 for y in range(height) if wrong[y][width - 1] == WHITE)
    dut._log.info(
        f"misaligned by one clock: {len(bad)} of {width * height} pixels wrong, "
        f"right border white in {right_edge} of {height} rows"
    )

    # The right-hand edge, magnified, with the misaligned frame below.
    crop = [r[-12:] for r in rows[:8]] + [[GREY] * 12] + [r[-12:] for r in wrong[:8]]
    write_png(os.path.join(BUILD, f"edge_{mode}.png"), crop, 16)
