#!/usr/bin/env python3
"""Instruction-set simulator for RV32I. Python standard library only.

    python3 tools/iss.py program.hex [--trace out.trace] [--limit N]

This is the reference model. One call to Iss.step() runs one whole instruction,
with no clock and no states. It is written from the RISC-V unprivileged spec,
chapter "RV32I Base Integer Instruction Set", and it must stay that way. Nothing
here comes from rv32i.v, rv_decode.v or asm.py. It also takes a different route
from the hardware wherever it can:

- Numbers are Python integers. A value is turned into a signed number when the
  spec says signed, and reduced to 32 bits only when it is stored.
- Immediates are gathered bit by bit from a table copied from the spec's figures.
- Memory is bytes. A halfword load reads two bytes, and nothing here knows about
  byte lanes or wstrb, except bus_write(), which is only for the trace.

The model stops at a trap, the same traps the core takes:
illegal instruction, ECALL, EBREAK, and misaligned jumps, loads and stores.

Using it from a test:

    model = Iss(Memory(words))
    done = model.step()        # a Retired, which says what that instruction did
    model.x, model.pc          # the state after it
"""

import argparse
import sys
from dataclasses import dataclass
from typing import Optional, Tuple

MASK = 0xFFFFFFFF
MEMORY_BYTES = 65536

# The causes, as the privileged spec numbers them in mcause.
CAUSE_JUMP_ALIGN = 0
CAUSE_ILLEGAL = 2
CAUSE_EBREAK = 3
CAUSE_LOAD_ALIGN = 4
CAUSE_STORE_ALIGN = 6
CAUSE_ECALL = 11

TRAP_NAMES = ["ILLEGAL", "ECALL", "EBREAK", "MISALIGNED_JAL", "MISALIGNED_JALR",
              "MISALIGNED_BRANCH", "MISALIGNED_LOAD", "MISALIGNED_STORE"]

# Major opcodes.
LUI, AUIPC, JAL, JALR, BRANCH, LOAD, STORE = 0x37, 0x17, 0x6F, 0x67, 0x63, 0x03, 0x23
OP_IMM, OP, MISC_MEM, SYSTEM = 0x13, 0x33, 0x0F, 0x73

BRANCH_NAMES = {0: "BEQ", 1: "BNE", 4: "BLT", 5: "BGE", 6: "BLTU", 7: "BGEU"}
LOAD_NAMES = {0: "LB", 1: "LH", 2: "LW", 4: "LBU", 5: "LHU"}
STORE_NAMES = {0: "SB", 1: "SH", 2: "SW"}
IMM_NAMES = {0: "ADDI", 2: "SLTI", 3: "SLTIU", 4: "XORI", 6: "ORI", 7: "ANDI"}
# OP is decoded on (funct7, funct3).
REG_NAMES = {(0x00, 0): "ADD", (0x20, 0): "SUB", (0x00, 1): "SLL", (0x00, 2): "SLT",
             (0x00, 3): "SLTU", (0x00, 4): "XOR", (0x00, 5): "SRL", (0x20, 5): "SRA",
             (0x00, 6): "OR", (0x00, 7): "AND"}
SHIFT_IMM_NAMES = {(0x00, 1): "SLLI", (0x00, 5): "SRLI", (0x20, 5): "SRAI"}

ALL_MNEMONICS = (["LUI", "AUIPC", "JAL", "JALR", "FENCE"] + list(LOAD_NAMES.values())
                 + list(STORE_NAMES.values()) + list(IMM_NAMES.values())
                 + list(SHIFT_IMM_NAMES.values()) + list(REG_NAMES.values()))

# Where each immediate bit comes from: (bit of the immediate, bit of the instruction).
# Copied from the figures in the spec, one format at a time. Bit 31 of the
# instruction is always the sign, so every bit above the highest one listed copies it.
IMMEDIATE_BITS = {
    "I": [(n, 20 + n) for n in range(12)],
    "S": [(n, 7 + n) for n in range(5)] + [(n, 20 + n) for n in range(5, 12)],
    "B": ([(n, 7 + n) for n in range(1, 5)] + [(n, 20 + n) for n in range(5, 11)]
          + [(11, 7), (12, 31)]),
    "U": [(n, n) for n in range(12, 32)],
    "J": ([(n, 20 + n) for n in range(1, 11)] + [(11, 20)]
          + [(n, n) for n in range(12, 20)] + [(20, 31)]),
}


def signed(value):
    """A 32-bit pattern as a number from -2**31 to 2**31 - 1."""
    value &= MASK
    return value - (1 << 32) if value >> 31 else value


def immediate(instr, kind):
    """The sign-extended immediate of one format, as a Python integer."""
    value = 0
    top = 0
    for imm_bit, instr_bit in IMMEDIATE_BITS[kind]:
        value |= ((instr >> instr_bit) & 1) << imm_bit
        top = max(top, imm_bit)
    if (instr >> 31) & 1:
        value -= 1 << (top + 1)       # bit 31 is the sign, at the top of the field
    return value


def fields(instr):
    return {"opcode": instr & 0x7F, "rd": (instr >> 7) & 31, "funct3": (instr >> 12) & 7,
            "rs1": (instr >> 15) & 31, "rs2": (instr >> 20) & 31, "funct7": instr >> 25}


def mnemonic(instr):
    """The instruction's name, or None if it is not an RV32I instruction."""
    f = fields(instr)
    op, funct3, funct7 = f["opcode"], f["funct3"], f["funct7"]
    if op == LUI:
        return "LUI"
    if op == AUIPC:
        return "AUIPC"
    if op == JAL:
        return "JAL"
    if op == JALR and funct3 == 0:
        return "JALR"
    if op == BRANCH:
        return BRANCH_NAMES.get(funct3)
    if op == LOAD:
        return LOAD_NAMES.get(funct3)
    if op == STORE:
        return STORE_NAMES.get(funct3)
    if op == OP_IMM:
        if funct3 in (1, 5):
            return SHIFT_IMM_NAMES.get((funct7, funct3))
        return IMM_NAMES[funct3]
    if op == OP:
        return REG_NAMES.get((funct7, funct3))
    if op == MISC_MEM and funct3 == 0:
        return "FENCE"
    if instr == 0x00000073:
        return "ECALL"
    if instr == 0x00100073:
        return "EBREAK"
    return None


def disassemble(instr):
    """One word as text, for failure reports. Registers are shown as x numbers."""
    name = mnemonic(instr)
    if name is None:
        return f"illegal {instr:08x}"
    f = fields(instr)
    rd, rs1, rs2 = f["rd"], f["rs1"], f["rs2"]
    low = name.lower()
    if name in ("LUI", "AUIPC"):
        return f"{low} x{rd}, 0x{instr >> 12:x}"
    if name == "JAL":
        return f"jal x{rd}, {immediate(instr, 'J'):+d}"
    if name == "JALR":
        return f"jalr x{rd}, {immediate(instr, 'I')}(x{rs1})"
    if name in BRANCH_NAMES.values():
        return f"{low} x{rs1}, x{rs2}, {immediate(instr, 'B'):+d}"
    if name in LOAD_NAMES.values():
        return f"{low} x{rd}, {immediate(instr, 'I')}(x{rs1})"
    if name in STORE_NAMES.values():
        return f"{low} x{rs2}, {immediate(instr, 'S')}(x{rs1})"
    if name in SHIFT_IMM_NAMES.values():
        return f"{low} x{rd}, x{rs1}, {rs2}"
    if name in IMM_NAMES.values():
        return f"{low} x{rd}, x{rs1}, {immediate(instr, 'I')}"
    if name in REG_NAMES.values():
        return f"{low} x{rd}, x{rs1}, x{rs2}"
    return low


def all_classes():
    """Every class Iss.step() can report. Coverage is measured against this list."""
    names = [m for m in ALL_MNEMONICS] + ["ECALL", "EBREAK", "ILLEGAL"]
    for branch in BRANCH_NAMES.values():
        names += [branch + "_taken", branch + "_not_taken"]
    names += TRAP_NAMES[3:]
    # Each place a byte or a halfword can sit in a word, and a write to x0.
    names += [f"{n}@{offset}" for n in ("LB", "LBU", "SB") for offset in range(4)]
    names += [f"{n}@{offset}" for n in ("LH", "LHU", "SH") for offset in (0, 2)]
    names += ["rd=x0"]
    return list(dict.fromkeys(names))


class Memory:
    """Bytes, little-endian. Only the low 16 address bits count, so the 64 KiB
    repeat through the whole 4 GiB address space. That is a fact about the test
    memory, not about RISC-V: the testbench memory does the same."""

    def __init__(self, words=(), size=MEMORY_BYTES):
        self.size = size
        self.data = bytearray(size)
        for index, word in enumerate(words):
            self.data[4 * index: 4 * index + 4] = (word & MASK).to_bytes(4, "little")

    def read(self, address, count):
        return int.from_bytes(bytes(self.data[(address + n) % self.size] for n in range(count)),
                              "little")

    def write(self, address, count, value):
        for n in range(count):
            self.data[(address + n) % self.size] = (value >> (8 * n)) & 0xFF

    def word(self, index):
        return self.read(4 * index, 4)


@dataclass
class Retired:
    """What one instruction did. The checkers compare this with the hardware."""
    pc: int
    instr: int
    name: str                          # a class from all_classes()
    next_pc: int
    rd: Optional[int]                  # the register written, or None. 0 counts as a write
    rd_value: int                      # what was written (0 for x0, which ignores it)
    write: Optional[Tuple[int, int, int]]   # (address, bytes, value) of a store, or None
    read: Optional[Tuple[int, int]]    # (address, bytes) of a load, or None
    trap: Optional[int]                # the cause, if it trapped

    @property
    def text(self):
        return disassemble(self.instr)

    def classes(self):
        """Every coverage class this instruction counts for."""
        names = [self.name]
        access = self.write or self.read
        if access and self.trap is None and self.name[:2] in ("LB", "LH", "SB", "SH"):
            names.append(f"{self.name}@{access[0] % 4}")
        if self.rd == 0 and self.trap is None:
            names.append("rd=x0")
        return names

    def bus_write(self):
        """The store as the memory interface shows it: (word address, wstrb, data),
        with the bytes that wstrb does not select set to 0."""
        if not self.write:
            return None
        address, count, value = self.write
        offset = address % 4
        strobe = ((1 << count) - 1) << offset
        return address - offset, strobe, (value << (8 * offset)) & MASK

    def trace_line(self):
        """One line for tb_trace.v: seven 32-bit fields, in hex."""
        strobe, address, data = 0, 0, 0
        if self.write:
            address, strobe, data = self.bus_write()
        info = ((self.rd or 0) | (int(self.rd is not None) << 8)
                | (int(self.trap is not None) << 12) | ((self.trap or 0) << 16) | (strobe << 24))
        rd_value = self.rd_value if self.rd else 0
        return "".join(f"{field & MASK:08X}" for field in
                       (self.pc, self.instr, self.next_pc, rd_value, info, address, data))


TRACE_END = "F" * 56


class Iss:
    """The state a programmer can see, and one method that runs one instruction."""

    def __init__(self, memory, pc=0):
        self.mem = memory
        self.x = [0] * 32
        self.pc = pc
        self.stopped = False

    def step(self):
        """Runs the instruction at pc, and returns a Retired."""
        if self.stopped:
            raise RuntimeError("the model has trapped, and only a reset leaves that")

        pc = self.pc
        instr = self.mem.read(pc, 4)
        name = mnemonic(instr)
        f = fields(instr)
        a, b = self.x[f["rs1"]], self.x[f["rs2"]]
        result = {"pc": pc, "instr": instr, "next_pc": (pc + 4) & MASK,
                  "rd": None, "rd_value": 0, "write": None, "read": None, "trap": None}

        def stop(cause, label):
            result.update(next_pc=pc, trap=cause)
            self.stopped = True
            return Retired(name=label, **result)

        def jump(target, label):
            """Jumps and taken branches. The target must be a multiple of 4,
            since this core has no 16-bit instructions."""
            target &= MASK
            if target % 4:
                return False
            result["next_pc"] = target
            return True

        if name is None:
            return stop(CAUSE_ILLEGAL, "ILLEGAL")
        if name == "ECALL":
            return stop(CAUSE_ECALL, "ECALL")
        if name == "EBREAK":
            return stop(CAUSE_EBREAK, "EBREAK")

        value = None                       # what rd gets, if it gets anything
        label = name
        op = f["opcode"]

        if name == "LUI":
            value = immediate(instr, "U")
        elif name == "AUIPC":
            value = pc + immediate(instr, "U")
        elif name == "JAL":
            if not jump(pc + immediate(instr, "J"), name):
                return stop(CAUSE_JUMP_ALIGN, "MISALIGNED_JAL")
            value = pc + 4
        elif name == "JALR":
            target = (a + immediate(instr, "I")) & ~1
            if not jump(target, name):
                return stop(CAUSE_JUMP_ALIGN, "MISALIGNED_JALR")
            value = pc + 4
        elif op == BRANCH:
            taken = {"BEQ": a == b, "BNE": a != b,
                     "BLT": signed(a) < signed(b), "BGE": signed(a) >= signed(b),
                     "BLTU": a < b, "BGEU": a >= b}[name]
            label = name + ("_taken" if taken else "_not_taken")
            if taken and not jump(pc + immediate(instr, "B"), name):
                return stop(CAUSE_JUMP_ALIGN, "MISALIGNED_BRANCH")
        elif op == LOAD:
            address = (a + immediate(instr, "I")) & MASK
            count = {"LB": 1, "LBU": 1, "LH": 2, "LHU": 2, "LW": 4}[name]
            if address % count:
                return stop(CAUSE_LOAD_ALIGN, "MISALIGNED_LOAD")
            raw = self.mem.read(address, count)
            if name in ("LB", "LH") and raw >> (8 * count - 1):
                raw -= 1 << (8 * count)            # sign-extend
            value = raw
            result["read"] = (address, count)
        elif op == STORE:
            address = (a + immediate(instr, "S")) & MASK
            count = {"SB": 1, "SH": 2, "SW": 4}[name]
            if address % count:
                return stop(CAUSE_STORE_ALIGN, "MISALIGNED_STORE")
            data = b & ((1 << (8 * count)) - 1)
            self.mem.write(address, count, data)
            result["write"] = (address, count, data)
        elif name == "FENCE":
            pass                                   # one access at a time: nothing to order
        else:
            # The ALU instructions. The second operand is rs2, or the I immediate.
            other = b if op == OP else immediate(instr, "I") & MASK
            shift = other % 32                     # only the low 5 bits count
            base = name.rstrip("I") if name not in ("SLTIU",) else "SLTU"
            value = {"ADD": a + other, "SUB": a - other,
                     "SLL": a << shift, "SRL": a >> shift, "SRA": signed(a) >> shift,
                     "SLT": int(signed(a) < signed(other)), "SLTU": int(a < other),
                     "XOR": a ^ other, "OR": a | other, "AND": a & other}[base]

        if value is not None:
            result["rd"] = f["rd"]
            result["rd_value"] = value & MASK if f["rd"] else 0
            if f["rd"]:
                self.x[f["rd"]] = value & MASK

        self.pc = result["next_pc"]
        return Retired(name=label, **result)


def load_hex(path):
    with open(path) as file:
        return [int(line, 16) for line in file if line.strip()]


def main():
    parser = argparse.ArgumentParser(description="Instruction-set simulator for RV32I")
    parser.add_argument("program", help=".hex file from asm.py")
    parser.add_argument("--trace", help="write one line per instruction, for tb_trace.v")
    parser.add_argument("--limit", type=int, default=100000, help="most instructions to run")
    args = parser.parse_args()

    model = Iss(Memory(load_hex(args.program)))
    lines = []
    while not model.stopped and len(lines) < args.limit:
        done = model.step()
        lines.append(done.trace_line())

    if not model.stopped:
        sys.exit(f"{args.program}: no trap after {args.limit} instructions")
    if done.trap != CAUSE_EBREAK:
        # Each program ends in EBREAK when its own checks pass, and in ECALL when not.
        sys.exit(f"{args.program}: stopped at {done.pc:08x}, {done.text}, with cause "
                 f"{done.trap}, not EBREAK")

    if args.trace:
        with open(args.trace, "w") as file:
            file.write("\n".join(lines + [TRACE_END]) + "\n")
    else:
        for n in range(32):
            print(f"x{n:<2} = {model.x[n]:08x}")


if __name__ == "__main__":
    main()
