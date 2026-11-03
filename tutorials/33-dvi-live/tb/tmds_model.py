"""TMDS encoding as the DVI 1.0 spec's flow charts give it, in Python.

encode(d, cnt) returns (q, new cnt) for a data character, token(c) the
character for control bits c = C1 * 2 + C0, and decode(q) undoes either.
Written from the spec, not from rtl/tmds_encoder.v, so the two can be compared.
"""

TOKENS = {0b00: 0b1101010100, 0b01: 0b0010101011, 0b10: 0b0101010100, 0b11: 0b1010101011}


def ones(v, bits=8):
    return bin(v & ((1 << bits) - 1)).count("1")


def encode(d, cnt):
    n1 = ones(d)
    xnor = n1 > 4 or (n1 == 4 and (d & 1) == 0)
    q_m = d & 1
    for i in range(1, 8):
        prev, bit = (q_m >> (i - 1)) & 1, (d >> i) & 1
        q_m |= ((1 - (prev ^ bit)) if xnor else (prev ^ bit)) << i
    q8 = 0 if xnor else 1
    n1m = ones(q_m)
    n0m = 8 - n1m
    inv = ~q_m & 0xFF
    if cnt == 0 or n1m == n0m:
        q = ((1 - q8) << 9) | (q8 << 8) | (q_m if q8 else inv)
        cnt += (n1m - n0m) if q8 else (n0m - n1m)
    elif (cnt > 0 and n1m > n0m) or (cnt < 0 and n0m > n1m):
        q = (1 << 9) | (q8 << 8) | inv
        cnt += 2 * q8 + (n0m - n1m)
    else:
        q = (q8 << 8) | q_m
        cnt += -2 * (1 - q8) + (n1m - n0m)
    return q, cnt


def token(c):
    return TOKENS[c]


def decode(q):
    """('ctl', c) for a control token, ('data', byte) otherwise."""
    for c, t in TOKENS.items():
        if q == t:
            return ("ctl", c)
    v = (~q & 0xFF) if q & 0x200 else q & 0xFF
    d = v & 1
    for i in range(1, 8):
        a, b = (v >> i) & 1, (v >> (i - 1)) & 1
        d |= ((a ^ b) if q & 0x100 else (1 - (a ^ b))) << i
    return ("data", d)


def disparity(q):
    """1s minus 0s in a 10-bit character."""
    return 2 * ones(q, 10) - 10


def reachable():
    """Every value cnt can take, starting from 0 after blanking."""
    seen, todo = {0}, [0]
    while todo:
        c = todo.pop()
        for d in range(256):
            c2 = encode(d, c)[1]
            if c2 not in seen:
                seen.add(c2)
                todo.append(c2)
    return sorted(seen)


def path_to(target):
    """A shortest list of bytes that takes cnt from 0 to target."""
    paths, todo = {0: []}, [0]
    while todo:
        c = todo.pop(0)
        if c == target:
            return paths[c]
        for d in range(256):
            c2 = encode(d, c)[1]
            if c2 not in paths:
                paths[c2] = paths[c] + [d]
                todo.append(c2)
    raise ValueError(target)
