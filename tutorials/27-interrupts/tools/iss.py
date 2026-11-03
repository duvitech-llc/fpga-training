#!/usr/bin/env python3
"""Instruction-set simulator for RV32I with machine mode. Python standard library only.

    python3 tools/iss.py program.hex [--limit N]

This is the reference model. One call to Iss.step() runs one whole instruction,
or takes one trap, with no clock and no states. Tutorial 21 wrote it from the
RISC-V unprivileged spec, chapter "RV32I Base Integer Instruction Set". Tutorial
27 adds, from the RISC-V privileged specification, the machine-mode CSRs, the
Zicsr instructions, MRET, traps that jump to mtvec, and interrupts. Nothing here
comes from rv32i.v, rv_csr.v, rv_decode.v or asm.py. It also takes a different
route from the hardware wherever it can:

- Numbers are Python integers. A value is turned into a signed number when the
  spec says signed, and reduced to 32 bits only when it is stored.
- Immediates are gathered bit by bit from a table copied from the spec's figures.
- Memory is bytes. A halfword load reads two bytes, and nothing here knows about
  byte lanes or wstrb, except bus_write().
- Each CSR is a whole 32-bit number with a mask of the bits that can change,
  where the hardware keeps only the bits it needs.

The model has no clock, so it cannot know when an interrupt line rises. The
caller passes mip, the two interrupt lines, to step(). The model decides for
itself whether to take an interrupt, from its own mstatus and mie. See step().

Using it from a test:

    model = Iss(Memory(words))
    done = model.step(mip)     # a Retired, which says what that instruction did
    model.x, model.pc          # the state after it
    model.csr_read(0x341)      # mepc
"""

import argparse
import sys
from dataclasses import dataclass
from typing import Optional, Tuple

MASK = 0xFFFFFFFF
MEMORY_BYTES = 65536

# The causes, as the privileged spec numbers them in mcause.
CAUSE_JUMP_ALIGN = 0
CAUSE_FETCH_FAULT = 1
CAUSE_ILLEGAL = 2
CAUSE_EBREAK = 3
CAUSE_LOAD_ALIGN = 4
CAUSE_LOAD_FAULT = 5
CAUSE_STORE_ALIGN = 6
CAUSE_STORE_FAULT = 7
CAUSE_ECALL = 11
INTERRUPT = 1 << 31
CAUSE_IRQ_TIMER = INTERRUPT | 7
CAUSE_IRQ_EXTERNAL = INTERRUPT | 11

# The interrupt bits, the same in mip and mie.
MTIP = 1 << 7
MEIP = 1 << 11
# The bits of mstatus.
MSTATUS_MIE = 1 << 3
MSTATUS_MPIE = 1 << 7
MSTATUS_MPP = 3 << 11

TRAP_NAMES = ["ILLEGAL", "ECALL", "EBREAK", "MISALIGNED_JAL", "MISALIGNED_JALR",
              "MISALIGNED_BRANCH", "MISALIGNED_LOAD", "MISALIGNED_STORE",
              "FETCH_FAULT", "LOAD_FAULT", "STORE_FAULT"]
IRQ_NAMES = ["IRQ_TIMER", "IRQ_EXTERNAL"]

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
CSR_NAMES = {1: "CSRRW", 2: "CSRRS", 3: "CSRRC", 5: "CSRRWI", 6: "CSRRSI", 7: "CSRRCI"}

ALL_MNEMONICS = (["LUI", "AUIPC", "JAL", "JALR", "FENCE"] + list(LOAD_NAMES.values())
                 + list(STORE_NAMES.values()) + list(IMM_NAMES.values())
                 + list(SHIFT_IMM_NAMES.values()) + list(REG_NAMES.values())
                 + list(CSR_NAMES.values()) + ["MRET"])

# The CSRs this core has: number -> (name, reset value, bits a write can change,
# bits that read as fixed ones). Written from the privileged spec's descriptions:
#   mstatus   MIE and MPIE can change. MPP is fixed at 11, machine mode, the only
#             mode there is.
#   misa      MXL = 1 (32 bits) and the I extension. Writes are ignored, as allowed.
#   mie, mip  MTIE/MTIP (bit 7) and MEIE/MEIP (bit 11). mip is the interrupt lines,
#             so a write cannot change it.
#   mtvec     direct mode only, so the mode bits 1:0 stay 0.
#   mepc      bits 1:0 stay 0, since every instruction is 4 bytes.
#   mcause    the interrupt bit, and codes up to 15.
#   the IDs   mvendorid, marchid, mimpid, mhartid and mconfigptr are 0. Their
#             numbers start with 11, so the spec makes them read-only.
CSRS = {
    0x300: ("mstatus",   0, MSTATUS_MIE | MSTATUS_MPIE, MSTATUS_MPP),
    0x301: ("misa",      0, 0, 0x4000_0100),
    0x304: ("mie",       0, MTIP | MEIP, 0),
    0x305: ("mtvec",     0, MASK & ~3, 0),
    0x310: ("mstatush",  0, 0, 0),
    0x340: ("mscratch",  0, MASK, 0),
    0x341: ("mepc",      0, MASK & ~3, 0),
    0x342: ("mcause",    0, INTERRUPT | 0xF, 0),
    0x343: ("mtval",     0, MASK, 0),
    0x344: ("mip",       0, 0, 0),
    0xF11: ("mvendorid", 0, 0, 0),
    0xF12: ("marchid",   0, 0, 0),
    0xF13: ("mimpid",    0, 0, 0),
    0xF14: ("mhartid",   0, 0, 0),
    0xF15: ("mconfigptr", 0, 0, 0),
}
CSR_NUMBER = {name: number for number, (name, *_rest) in CSRS.items()}

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
            "rs1": (instr >> 15) & 31, "rs2": (instr >> 20) & 31, "funct7": instr >> 25,
            "csr": instr >> 20}


def mnemonic(instr):
    """The instruction's name, or None if it is not an instruction this core has.
    Whether a CSR instruction names a CSR that exists is decided when it runs."""
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
    if instr == 0x30200073:
        return "MRET"
    if op == SYSTEM:
        return CSR_NAMES.get(funct3)
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
    if name in CSR_NAMES.values():
        csr = CSRS.get(f["csr"], (f"0x{f['csr']:03x}",))[0]
        source = rs1 if name.endswith("I") else f"x{rs1}"
        return f"{low} x{rd}, {csr}, {source}"
    return low


def all_classes():
    """Every class Iss.step() can report. Coverage is measured against this list."""
    names = [m for m in ALL_MNEMONICS] + ["ECALL", "EBREAK", "ILLEGAL"]
    for branch in BRANCH_NAMES.values():
        names += [branch + "_taken", branch + "_not_taken"]
    names += TRAP_NAMES[3:] + IRQ_NAMES
    # Each place a byte or a halfword can sit in a word, and a write to x0.
    names += [f"{n}@{offset}" for n in ("LB", "LBU", "SB") for offset in range(4)]
    names += [f"{n}@{offset}" for n in ("LH", "LHU", "SH") for offset in (0, 2)]
    names += ["rd=x0"]
    return list(dict.fromkeys(names))


class Memory:
    """Bytes, little-endian. Only the low 16 address bits count, so the 64 KiB
    repeat through the whole 4 GiB address space, and nothing ever faults. That is
    a fact about this test memory, not about RISC-V. soc_model.py has a memory
    with the system's map, where an access to nothing faults."""

    def __init__(self, words=(), size=MEMORY_BYTES):
        self.size = size
        self.data = bytearray(size)
        for index, word in enumerate(words):
            self.data[4 * index: 4 * index + 4] = (word & MASK).to_bytes(4, "little")

    def faults(self, address, count, write):
        return False

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
    """What one step did. The checkers compare this with the hardware."""
    pc: int
    instr: int
    name: str                          # a class from all_classes()
    next_pc: int
    rd: Optional[int]                  # the register written, or None. 0 counts as a write
    rd_value: int                      # what was written (0 for x0, which ignores it)
    write: Optional[Tuple[int, int, int]]   # (address, bytes, value) of a store, or None
    read: Optional[Tuple[int, int]]    # (address, bytes) of a load, or None
    trap: Optional[int]                # mcause, if it trapped or took an interrupt

    @property
    def text(self):
        return disassemble(self.instr)

    @property
    def interrupt(self):
        return self.trap is not None and bool(self.trap & INTERRUPT)

    def classes(self):
        """Every coverage class this step counts for."""
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


class Iss:
    """The state a programmer can see, and one method that runs one instruction."""

    def __init__(self, memory, pc=0):
        self.mem = memory
        self.x = [0] * 32
        self.pc = pc
        self.csr = {number: reset for number, (_, reset, _, _) in CSRS.items()}
        self.mip = 0

    # ----- CSRs -----

    def csr_read(self, number):
        """The value a CSR instruction would read. mip is the lines last passed to step()."""
        if number == CSR_NUMBER["mip"]:
            return self.mip & (MTIP | MEIP)
        _, _, writable, ones = CSRS[number]
        return (self.csr[number] & writable) | ones

    def csr_write(self, number, value):
        _, _, writable, _ = CSRS[number]
        self.csr[number] = value & writable

    def mstatus_bit(self, bit):
        return bool(self.csr[0x300] & bit)

    # ----- One step -----

    def step(self, mip=0):
        """Runs the instruction at pc, or takes a trap, and returns a Retired.

        mip holds the interrupt lines, MTIP and MEIP, as the hardware saw them in
        the clock where it decided this instruction: they are copied from the
        hardware, since the model has no clock. Whether to take an interrupt is
        decided here: before the instruction runs, if mstatus.MIE is set and a
        line is both high in mip and enabled in mie. External comes before timer.

        One exception comes even before that. The core decides about interrupts
        after the fetch, so a fetch that faults traps first, whatever mip holds.
        """
        self.mip = mip
        pc = self.pc
        result = {"pc": pc, "instr": 0, "next_pc": (pc + 4) & MASK,
                  "rd": None, "rd_value": 0, "write": None, "read": None, "trap": None}

        def trap(cause, label, tval):
            """Into the handler: the privileged spec's steps for a trap in machine mode."""
            mie = self.mstatus_bit(MSTATUS_MIE)
            mstatus = self.csr[0x300] & ~(MSTATUS_MIE | MSTATUS_MPIE)
            self.csr[0x300] = mstatus | (MSTATUS_MPIE if mie else 0)
            self.csr_write(0x341, pc)                  # mepc
            self.csr_write(0x342, cause)               # mcause
            self.csr_write(0x343, tval & MASK)         # mtval
            self.pc = self.csr_read(0x305)             # mtvec, direct mode
            result.update(next_pc=self.pc, trap=cause)
            return Retired(name=label, **result)

        if self.mem.faults(pc, 4, write=False):
            return trap(CAUSE_FETCH_FAULT, "FETCH_FAULT", pc)
        instr = self.mem.read(pc, 4)
        result["instr"] = instr

        pending = mip & self.csr_read(0x304)            # mip & mie
        if self.mstatus_bit(MSTATUS_MIE) and pending:
            if pending & MEIP:
                return trap(CAUSE_IRQ_EXTERNAL, "IRQ_EXTERNAL", 0)
            return trap(CAUSE_IRQ_TIMER, "IRQ_TIMER", 0)

        name = mnemonic(instr)
        f = fields(instr)
        a, b = self.x[f["rs1"]], self.x[f["rs2"]]

        def jump(target):
            """Jumps and taken branches. The target must be a multiple of 4,
            since this core has no 16-bit instructions."""
            target &= MASK
            if target % 4:
                return False
            result["next_pc"] = target
            return True

        if name is None:
            return trap(CAUSE_ILLEGAL, "ILLEGAL", instr)
        if name == "ECALL":
            return trap(CAUSE_ECALL, "ECALL", 0)
        if name == "EBREAK":
            return trap(CAUSE_EBREAK, "EBREAK", pc)

        value = None                       # what rd gets, if it gets anything
        label = name
        op = f["opcode"]

        if name == "LUI":
            value = immediate(instr, "U")
        elif name == "AUIPC":
            value = pc + immediate(instr, "U")
        elif name == "JAL":
            target = pc + immediate(instr, "J")
            if not jump(target):
                return trap(CAUSE_JUMP_ALIGN, "MISALIGNED_JAL", target)
            value = pc + 4
        elif name == "JALR":
            target = (a + immediate(instr, "I")) & ~1
            if not jump(target):
                return trap(CAUSE_JUMP_ALIGN, "MISALIGNED_JALR", target)
            value = pc + 4
        elif op == BRANCH:
            taken = {"BEQ": a == b, "BNE": a != b,
                     "BLT": signed(a) < signed(b), "BGE": signed(a) >= signed(b),
                     "BLTU": a < b, "BGEU": a >= b}[name]
            label = name + ("_taken" if taken else "_not_taken")
            target = pc + immediate(instr, "B")
            if taken and not jump(target):
                return trap(CAUSE_JUMP_ALIGN, "MISALIGNED_BRANCH", target)
        elif op == LOAD:
            address = (a + immediate(instr, "I")) & MASK
            count = {"LB": 1, "LBU": 1, "LH": 2, "LHU": 2, "LW": 4}[name]
            if address % count:
                return trap(CAUSE_LOAD_ALIGN, "MISALIGNED_LOAD", address)
            if self.mem.faults(address, count, write=False):
                return trap(CAUSE_LOAD_FAULT, "LOAD_FAULT", address)
            raw = self.mem.read(address, count)
            if name in ("LB", "LH") and raw >> (8 * count - 1):
                raw -= 1 << (8 * count)            # sign-extend
            value = raw
            result["read"] = (address, count)
        elif op == STORE:
            address = (a + immediate(instr, "S")) & MASK
            count = {"SB": 1, "SH": 2, "SW": 4}[name]
            if address % count:
                return trap(CAUSE_STORE_ALIGN, "MISALIGNED_STORE", address)
            if self.mem.faults(address, count, write=True):
                return trap(CAUSE_STORE_FAULT, "STORE_FAULT", address)
            data = b & ((1 << (8 * count)) - 1)
            self.mem.write(address, count, data)
            result["write"] = (address, count, data)
        elif name == "FENCE":
            pass                                   # one access at a time: nothing to order
        elif name == "MRET":
            # Back from the handler: MIE from MPIE, then MPIE set, and pc from mepc.
            mpie = self.mstatus_bit(MSTATUS_MPIE)
            mstatus = self.csr[0x300] & ~MSTATUS_MIE
            self.csr[0x300] = mstatus | MSTATUS_MPIE | (MSTATUS_MIE if mpie else 0)
            result["next_pc"] = self.csr_read(0x341)
        elif name in CSR_NAMES.values():
            # The CSR instructions. The source is rs1, or for the I forms the 5-bit
            # number in its place. W always writes. S and C write only when the
            # source field is not 0, so they can read a read-only CSR.
            number = f["csr"]
            source = f["rs1"] if name.endswith("I") else a
            writes = name.startswith("CSRRW") or f["rs1"] != 0
            if number not in CSRS or (writes and number >> 10 == 3):
                return trap(CAUSE_ILLEGAL, "ILLEGAL", instr)
            old = self.csr_read(number)
            if writes:
                new = {"CSRRW": source, "CSRRS": old | source,
                       "CSRRC": old & ~source}[name.rstrip("I")]
                self.csr_write(number, new)
            value = old
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
    parser.add_argument("--limit", type=int, default=100000, help="most instructions to run")
    args = parser.parse_args()

    # With no interrupt lines, until the first EBREAK.
    model = Iss(Memory(load_hex(args.program)))
    for _ in range(args.limit):
        done = model.step()
        if done.name == "EBREAK":
            break
    else:
        sys.exit(f"{args.program}: no EBREAK after {args.limit} instructions")
    for n in range(32):
        print(f"x{n:<2} = {model.x[n]:08x}")


if __name__ == "__main__":
    main()
