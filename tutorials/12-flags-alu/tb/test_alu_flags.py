import random

import cocotb
from cocotb.triggers import Timer

OPS = ["add", "adc", "sub", "sbc", "and", "or", "xor", "not",
       "shl", "shr", "asr", "rol", "ror", "pass_b", "unused14", "unused15"]


def signed(value, width):
    """The number that these bits mean in two's complement."""
    return value - 2**width if value >= 2 ** (width - 1) else value


def model(name, a, b, carry_in, width):
    """Return the expected y, c and v, with ordinary integer arithmetic only.

    Python integers never overflow, so each flag is its definition: did the
    true answer fit? Nothing here looks at sign bits, as the design does.
    """
    size = 2**width
    sa, sb = signed(a, width), signed(b, width)
    bits = [(a >> i) % 2 for i in range(width)]
    bits_b = [(b >> i) % 2 for i in range(width)]

    def fits(answer):
        return -size // 2 <= answer < size // 2

    if name in ("add", "adc"):
        extra = carry_in if name == "adc" else 0
        total = a + b + extra
        return total % size, int(total >= size), int(not fits(sa + sb + extra))
    if name in ("sub", "sbc"):
        borrow_in = 1 - carry_in if name == "sbc" else 0
        total = a - b - borrow_in
        return total % size, int(total >= 0), int(not fits(sa - sb - borrow_in))
    if name in ("and", "or", "xor"):
        rule = {"and": min, "or": max, "xor": lambda p, q: (p + q) % 2}[name]
        return sum(rule(p, q) * 2**i for i, (p, q) in enumerate(zip(bits, bits_b))), 0, 0
    if name == "not":
        return size - 1 - a, 0, 0
    if name in ("shl", "rol"):
        extra = carry_in if name == "rol" else 0
        total = 2 * a + extra
        return total % size, int(total >= size), int(not fits(2 * sa + extra))
    if name == "shr":
        return a // 2, a % 2, 0
    if name == "asr":
        return (sa // 2) % size, a % 2, 0  # Python's // rounds down, as ASR does
    if name == "ror":
        return (a + carry_in * size) // 2, a % 2, 0
    if name == "pass_b":
        return b, 0, 0
    return 0, 0, 0


def pick(width):
    """Mostly random, plus the corner values that random numbers almost never hit."""
    top = 2**width - 1
    a, b = random.getrandbits(width), random.getrandbits(width)
    kind = random.random()
    if kind < 0.1:
        b = a
    elif kind < 0.2:
        a = 2 ** (width - 1)  # most negative
    elif kind < 0.3:
        b = 2 ** (width - 1)
    elif kind < 0.4:
        b = top
    elif kind < 0.5:
        a = 2 ** (width - 1) - 1  # most positive
    elif kind < 0.6:
        b = 0
    return a, b


@cocotb.test()
async def random_inputs(dut):
    """Compare y and all four flags against a Python model for random inputs."""
    width = int(dut.WIDTH.value)
    seen = {"c_only": 0, "v_only": 0, "c_and_v": 0, "neither": 0, "zero": 0,
            "negative": 0, "sub_of_most_negative": 0, "v_on_shift": 0,
            "orders_disagree": 0}

    for _ in range(20000):
        op = random.randrange(len(OPS))
        name = OPS[op]
        a, b = pick(width)
        carry_in = random.getrandbits(1)
        dut.op.value = op
        dut.a.value = a
        dut.b.value = b
        dut.carry_in.value = carry_in

        # There is no clock to wait for, only time for the logic to settle.
        await Timer(1, unit="ns")

        y, c, v = model(name, a, b, carry_in, width)
        message = f"{name} a={a:#x} b={b:#x} carry_in={carry_in}"
        assert dut.y.value == y, message
        assert dut.c.value == c, message
        assert dut.v.value == v, message
        assert dut.z.value == (y == 0), message
        assert dut.n.value == (y >= 2 ** (width - 1)), message

        arithmetic = name in ("add", "adc", "sub", "sbc")
        seen["c_only"] += arithmetic and c and not v
        seen["v_only"] += arithmetic and v and not c
        seen["c_and_v"] += arithmetic and c and v
        seen["neither"] += arithmetic and not c and not v
        seen["zero"] += y == 0
        seen["negative"] += y >= 2 ** (width - 1)
        seen["sub_of_most_negative"] += name == "sub" and b == 2 ** (width - 1)
        seen["v_on_shift"] += name in ("shl", "rol") and v

        # A comparison where the signed and the unsigned order give opposite answers.
        sa, sb = signed(a, width), signed(b, width)
        seen["orders_disagree"] += name == "sub" and (a < b) != (sa < sb)

    for name, count in seen.items():
        assert count > 0, f"the random inputs never reached {name}"
    dut._log.info(f"WIDTH={width} {seen}")
