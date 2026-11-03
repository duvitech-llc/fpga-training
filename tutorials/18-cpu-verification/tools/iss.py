#!/usr/bin/env python3
"""Instruction-set simulator for the course CPU. Python standard library only.

    python3 tools/iss.py program.hex [--trace out.trace] [--limit N]

This is the reference model: one call to Iss.step() runs one whole instruction,
with no clocks, no states and no pipeline. It is written from the architecture
spec, and it must stay that way. Nothing here comes from cpu.v, decode.v,
alu_flags.v or asm.py, and its ALU works on plain Python integers, so that it
gets each answer by a different route from the hardware. A model copied from the
design has the design's bugs.

Using it from a test:

    model = Iss(words)            # 256 instruction words
    done = model.step()           # a Retired, which says what that instruction did
    model.regs, model.flags()     # the state after it

To add memory-mapped I/O, pass any object that supports [] as data=.
"""

import argparse
import sys
from dataclasses import dataclass
from typing import Optional, Tuple

BYTE = 256

ALU_NAMES = ["ADD", "ADC", "SUB", "SBC", "AND", "OR", "XOR", "NOT",
             "SHL", "SHR", "ASR", "ROL", "ROR", "MOV", "CMP"]
ONE_REGISTER = ("NOT", "SHL", "SHR", "ASR", "ROL", "ROR")
BRANCH_NAMES = ["BEQ", "BNE", "BCS", "BCC", "BMI", "BPL", "BVS", "BVC",
                "BLT", "BGE", "BLO", "BHS"]
ILLEGAL_NAMES = ["ILLEGAL_SYSTEM", "ILLEGAL_ALU", "ILLEGAL_BRANCH", "ILLEGAL_OP_F"]

# One line of a trace is a hex number of this many digits. A line of all F is the end.
TRACE_DIGITS = 20
TRACE_LINES = 4096


def signed(value):
    """An 8-bit pattern as a number from -128 to 127."""
    return value - BYTE if value >= BYTE // 2 else value


def fits(exact):
    """True if a signed answer fits in 8 bits. If not, that is signed overflow."""
    return -128 <= exact <= 127


def alu(name, a, b, carry):
    """Returns (y, c, v) for one ALU operation, from what the operation means.

    Each sum is worked out twice, as unsigned and as signed numbers, with
    nothing to overflow in Python. c and v then come from those true answers.
    Carry after a subtraction is NOT borrow: c is 1 when nothing was borrowed.
    """
    if name in ("ADD", "ADC"):
        extra = carry if name == "ADC" else 0
        total = a + b + extra
        return total % BYTE, int(total >= BYTE), int(not fits(signed(a) + signed(b) + extra))

    if name in ("SUB", "SBC", "CMP"):
        borrow = 1 - carry if name == "SBC" else 0
        total = a - b - borrow
        return total % BYTE, int(total >= 0), int(not fits(signed(a) - signed(b) - borrow))

    if name == "SHL":
        y = a * 2 % BYTE
        return y, a // 128, int(y // 128 != a // 128)
    if name == "ROL":
        y = (a * 2 + carry) % BYTE
        return y, a // 128, int(y // 128 != a // 128)
    if name == "SHR":
        return a // 2, a % 2, 0
    if name == "ASR":
        return (signed(a) // 2) % BYTE, a % 2, 0     # // rounds down, which is what ASR does
    if name == "ROR":
        return a // 2 + carry * 128, a % 2, 0

    # Logic: c and v are always 0.
    y = {"AND": a & b, "OR": a | b, "XOR": a ^ b, "NOT": 255 - a, "MOV": b}[name]
    return y, 0, 0


def branch_taken(name, z, c, n, v):
    """The spec's table of branch conditions."""
    return {"BEQ": z, "BNE": not z, "BCS": c, "BCC": not c, "BMI": n, "BPL": not n,
            "BVS": v, "BVC": not v, "BLT": n != v, "BGE": n == v,
            "BLO": not c, "BHS": c}[name]


def fields(word):
    """Splits a word into (op, rd, rs, imm)."""
    return word >> 12, (word >> 10) & 3, (word >> 8) & 3, word & 255


def illegal_kind(word):
    """Names the spec's kind of illegal word, or returns None if this word is legal."""
    op, _, _, imm = fields(word)
    if op == 0x0 and imm > 1:
        return "ILLEGAL_SYSTEM"
    if op == 0x1 and imm % 16 == 15:
        return "ILLEGAL_ALU"
    if op == 0x9 and (word >> 8) & 15 >= 12:
        return "ILLEGAL_BRANCH"
    if op == 0xF:
        return "ILLEGAL_OP_F"
    return None


def disassemble(word):
    """One word as assembler text, for failure reports."""
    op, rd, rs, imm = fields(word)
    bad = illegal_kind(word)
    if bad:
        return f"illegal word {word:04X} ({bad})"
    if op == 0x0:
        return "HALT" if imm else "NOP"
    if op == 0x1:
        name = ALU_NAMES[imm % 16]
        return f"{name} R{rd}" if name in ONE_REGISTER else f"{name} R{rd}, R{rs}"
    if op in (0x2, 0x3, 0x4, 0x5):
        return f"{['LDI', 'ADDI', 'CMPI', 'ANDI'][op - 2]} R{rd}, 0x{imm:02X}"
    if op in (0x6, 0x7):
        return f"{'LD' if op == 6 else 'ST'} R{rd}, [R{rs}+0x{imm:02X}]"
    if op == 0x8:
        return f"JMP 0x{imm:02X}"
    if op == 0x9:
        return f"{BRANCH_NAMES[(word >> 8) & 15]} 0x{imm:02X}"
    if op == 0xA:
        return f"CALL 0x{imm:02X}"
    if op == 0xB:
        return "RET"
    if op == 0xC:
        return f"PUSH R{rs}"
    if op == 0xD:
        return f"POP R{rd}"
    return f"JR R{rs}"


def all_classes():
    """Every class Iss.step() can report. Coverage is measured against this list."""
    names = ["NOP", "HALT", "LDI", "ADDI", "CMPI", "ANDI", "LD", "ST", "JMP", "CALL", "RET",
             "PUSH", "PUSH_R3", "POP", "POP_R3", "JR"]
    names += ALU_NAMES + ILLEGAL_NAMES
    for name in BRANCH_NAMES:
        names += [name + "_taken", name + "_not_taken"]
    return names


def reachable_flags():
    """Every {z, c, n, v} the architecture can hold, found by trying every ALU input.

    Not all 16 can happen: z and n together cannot, since 0 is not negative. Coverage
    must not demand a combination that does not exist.
    """
    seen = {(0, 0, 0, 0)}                             # the flags after reset
    for name in ALU_NAMES:
        for a in range(BYTE):
            for b in range(BYTE):
                for carry in (0, 1):
                    y, c, v = alu(name, a, b, carry)
                    seen.add((int(y == 0), c, y // 128, v))
    return seen


@dataclass
class Retired:
    """What one instruction did. The checker compares this with the hardware."""
    pc: int
    instr: int
    name: str                                # a class from all_classes()
    next_pc: int
    regs: Tuple[int, int, int, int]          # after the instruction
    flags: Tuple[int, int, int, int]         # z, c, n, v after the instruction
    write: Optional[Tuple[int, int]]         # (address, value), or None
    stopped: bool                            # HALT or illegal
    illegal: bool

    @property
    def text(self):
        return disassemble(self.instr)

    def trace_line(self):
        """One line for a trace file: pc, instr, R0 to R3, zcnv, write."""
        z, c, n, v = self.flags
        written, address, value = (1, *self.write) if self.write else (0, 0, 0)
        return (f"{self.pc:02X}{self.instr:04X}"
                + "".join(f"{reg:02X}" for reg in self.regs)
                + f"{z * 8 + c * 4 + n * 2 + v:X}{written:X}{address:02X}{value:02X}")


class Iss:
    """The state a programmer can see, and one method that runs one instruction."""

    def __init__(self, words, data=None):
        self.words = words
        self.mem = data if data is not None else [0] * BYTE
        self.regs = [0, 0, 0, 0]
        self.z = self.c = self.n = self.v = 0
        self.pc = 0
        self.stopped = False

    def flags(self):
        return (self.z, self.c, self.n, self.v)

    def set_flags(self, y, c, v):
        self.z, self.c, self.n, self.v = int(y == 0), c, y // 128, v

    def run_alu(self, name, a, b):
        y, c, v = alu(name, a, b, self.c)
        self.set_flags(y, c, v)
        return y

    def push(self, value):
        """Decrement R3, then store at the new R3."""
        self.regs[3] = (self.regs[3] - 1) % BYTE
        self.mem[self.regs[3]] = value
        return (self.regs[3], value)

    def pop(self):
        """Load from R3, then increment R3."""
        value = self.mem[self.regs[3]]
        self.regs[3] = (self.regs[3] + 1) % BYTE
        return value

    def step(self):
        """Runs the instruction at pc, and returns a Retired."""
        if self.stopped:
            raise RuntimeError("the model has stopped, and only a reset leaves that")

        pc = self.pc
        word = self.words[pc]
        op, rd, rs, imm = fields(word)
        regs = self.regs
        next_pc = (pc + 1) % BYTE
        write = None
        name = illegal_kind(word)
        illegal = name is not None

        if illegal:
            next_pc = pc
        elif op == 0x0:
            name = "HALT" if imm else "NOP"
            if imm:
                next_pc = pc
        elif op == 0x1:
            name = ALU_NAMES[imm % 16]
            y = self.run_alu(name, regs[rd], regs[rs])
            if name != "CMP":
                regs[rd] = y
        elif op == 0x2:
            name = "LDI"
            regs[rd] = imm
        elif op == 0x3:
            name = "ADDI"
            regs[rd] = self.run_alu("ADD", regs[rd], imm)
        elif op == 0x4:
            name = "CMPI"
            self.run_alu("SUB", regs[rd], imm)
        elif op == 0x5:
            name = "ANDI"
            regs[rd] = self.run_alu("AND", regs[rd], imm)
        elif op == 0x6:
            name = "LD"
            regs[rd] = self.mem[(regs[rs] + imm) % BYTE]
        elif op == 0x7:
            name = "ST"
            address = (regs[rs] + imm) % BYTE
            self.mem[address] = regs[rd]
            write = (address, regs[rd])
        elif op == 0x8:
            name = "JMP"
            next_pc = imm
        elif op == 0x9:
            base = BRANCH_NAMES[(word >> 8) & 15]
            taken = branch_taken(base, self.z, self.c, self.n, self.v)
            name = base + ("_taken" if taken else "_not_taken")
            if taken:
                next_pc = imm
        elif op == 0xA:
            name = "CALL"
            write = self.push(next_pc)
            next_pc = imm
        elif op == 0xB:
            name = "RET"
            next_pc = self.pop()
        elif op == 0xC:
            name = "PUSH_R3" if rs == 3 else "PUSH"
            write = self.push(regs[rs])
        elif op == 0xD:
            name = "POP_R3" if rd == 3 else "POP"
            value = self.pop()
            regs[rd] = value                     # after the pop, so POP R3 keeps the load
        else:
            name = "JR"
            next_pc = regs[rs]

        stopped = illegal or name == "HALT"
        self.pc = next_pc
        self.stopped = stopped
        return Retired(pc, word, name, next_pc, tuple(regs), self.flags(), write, stopped, illegal)


def read_hex(path):
    """Reads the assembler's output: one 16-bit word per line."""
    with open(path) as file:
        words = [int(line, 16) for line in file.read().split()]
    if len(words) != BYTE:
        sys.exit(f"{path}: expected {BYTE} words, found {len(words)}")
    return words


def main():
    parser = argparse.ArgumentParser(description="Instruction-set simulator for the course CPU")
    parser.add_argument("program", help="a .hex file from tools/asm.py")
    parser.add_argument("--trace", help="write one line per instruction, for tb_trace.v")
    parser.add_argument("--limit", type=int, default=TRACE_LINES - 1,
                        help="stop after this many instructions")
    args = parser.parse_args()

    model = Iss(read_hex(args.program))
    lines = []
    while not model.stopped and len(lines) < args.limit:
        lines.append(model.step().trace_line())

    if not model.stopped:
        sys.exit(f"{args.program}: no HALT after {args.limit} instructions")

    if args.trace:
        padding = ["F" * TRACE_DIGITS] * (TRACE_LINES - len(lines))
        with open(args.trace, "w") as file:
            file.write("\n".join(lines + padding) + "\n")

    regs = " ".join(f"R{n}={value:02X}" for n, value in enumerate(model.regs))
    print(f"{args.program}: {len(lines)} instructions, pc={model.pc:02X} {regs}")


if __name__ == "__main__":
    main()
