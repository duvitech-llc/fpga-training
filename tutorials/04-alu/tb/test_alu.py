import random

import cocotb
from cocotb.triggers import Timer

OPS = ["add", "sub", "and", "or", "xor", "shl", "shr", "slt"]


def model(op, a, b, width):
    """Return the expected y and carry for one operation."""
    mask = (1 << width) - 1
    shift = b & ((1 << (width - 1).bit_length()) - 1)
    signed_a = a - (1 << width) if a >> (width - 1) else a
    signed_b = b - (1 << width) if b >> (width - 1) else b

    if op == "add":
        return (a + b) & mask, int(a + b > mask)
    if op == "sub":
        return (a - b) & mask, int(a < b)
    if op == "and":
        return a & b, 0
    if op == "or":
        return a | b, 0
    if op == "xor":
        return a ^ b, 0
    if op == "shl":
        return (a << shift) & mask, 0
    if op == "shr":
        return a >> shift, 0
    return int(signed_a < signed_b), 0


def pick(width):
    """Mostly random, plus the corner values that random numbers almost never hit."""
    mask = (1 << width) - 1
    a, b = random.getrandbits(width), random.getrandbits(width)
    kind = random.random()
    if kind < 0.1:
        b = a
    elif kind < 0.2:
        a = 0
    elif kind < 0.3:
        b = mask
    elif kind < 0.4:
        a = 1 << (width - 1)
    return a, b


@cocotb.test()
async def random_inputs(dut):
    """Compare y, carry and zero against a Python model for random inputs."""
    width = int(dut.WIDTH.value)
    seen = {"carry": 0, "borrow": 0, "zero": 0, "slt": 0, "slt_mixed_signs": 0}

    for _ in range(5000):
        op = random.randrange(len(OPS))
        a, b = pick(width)
        dut.op.value = op
        dut.a.value = a
        dut.b.value = b

        # There is no clock to wait for, only time for the logic to settle.
        await Timer(1, unit="ns")

        y, carry = model(OPS[op], a, b, width)
        message = f"{OPS[op]} a={a:#x} b={b:#x}"
        assert dut.y.value == y, message
        assert dut.carry.value == carry, message
        assert dut.zero.value == (y == 0), message

        seen["carry"] += OPS[op] == "add" and carry
        seen["borrow"] += OPS[op] == "sub" and carry
        seen["zero"] += y == 0
        seen["slt"] += OPS[op] == "slt" and y
        seen["slt_mixed_signs"] += OPS[op] == "slt" and (a ^ b) >> (width - 1)

    for name, count in seen.items():
        assert count > 0, f"the random inputs never reached {name}"
    dut._log.info(f"WIDTH={width} {seen}")
