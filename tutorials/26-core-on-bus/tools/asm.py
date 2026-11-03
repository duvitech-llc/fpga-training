#!/usr/bin/env python3
"""Two-pass assembler for RV32I. Python standard library only.

    python3 tools/asm.py program.asm program.hex [--list]

This is Tutorial 16's assembler, grown to the RISC-V base integer instruction set.
The method is the same. Pass 1 gives every line its address, which fills the
symbol table. Pass 2 turns each instruction into 32-bit words.

The output is one 32-bit word per line, in hex, from address 0 up to the last
word used, ready for $readmemh. Words that nothing uses hold 00000000, which is
not an instruction, so running into one traps. Any error stops the assembler,
names the line, and writes no output.

Source syntax is the usual RISC-V syntax, as GNU as accepts it:

    # A comment runs to the end of the line.
    .equ   COUNT, 10             # a named constant
    .org   0x100                 # the next word goes at this byte address
    start: li    a0, COUNT       # a label is the address of what follows it
           lw    t0, 4(sp)       # loads and stores: offset(base)
           addi  a0, a0, -1
           bnez  a0, start       # branch targets are labels; the offset is worked out
    table: .word 1, 2, start     # 32-bit data

Registers are x0 to x31, or their ABI names: zero, ra, sp, gp, tp, t0 to t6,
s0 to s11 (s0 is also fp) and a0 to a7.

Numbers are decimal, 0x hex or 0b binary, and an operand may add or subtract
numbers and symbols, such as table+8. %hi(x) and %lo(x) split a 32-bit value for
LUI and ADDI, with the rounding that makes them add up.

Pseudo-instructions, and what they become:

    nop               addi x0, x0, 0
    li   rd, value    addi rd, x0, value, or lui rd, %hi(value) and addi rd, rd, %lo(value)
    la   rd, label    auipc rd, %hi(label - here) and addi rd, rd, %lo(label - here)
    mv   rd, rs       addi rd, rs, 0
    not  rd, rs       xori rd, rs, -1
    neg  rd, rs       sub  rd, x0, rs
    seqz rd, rs       sltiu rd, rs, 1
    snez rd, rs       sltu rd, x0, rs
    j    label        jal  x0, label
    jal  label        jal  ra, label
    jr   rs           jalr x0, 0(rs)
    jalr rs           jalr ra, 0(rs)
    ret               jalr x0, 0(ra)
    call label        jal  ra, label
    beqz, bnez, blez, bgez, bltz, bgtz rs, label    compare with x0
    bgt, ble, bgtu, bleu  rs, rt, label             blt, bge, bltu, bgeu with rs and rt swapped

GNU as turns call into AUIPC and JALR, so it can reach any address. Here memory is
64 KiB, and JAL reaches 1 MiB either way, so call is one JAL.

li and .org work during pass 1, so they can only use numbers and earlier symbols.
Mnemonics, directives and registers may be in either case. Symbols are case sensitive.
"""

import argparse
import re
import sys

MEMORY_BYTES = 65536

ABI_NAMES = ["zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1",
             "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7",
             "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11",
             "t3", "t4", "t5", "t6"]
REGISTERS = {f"x{n}": n for n in range(32)}
REGISTERS.update({name: n for n, name in enumerate(ABI_NAMES)})
REGISTERS["fp"] = 8

# The major opcodes, bits 6 to 0.
OP_LUI, OP_AUIPC, OP_JAL, OP_JALR = 0x37, 0x17, 0x6F, 0x67
OP_BRANCH, OP_LOAD, OP_STORE = 0x63, 0x03, 0x23
OP_IMM, OP_REG, OP_FENCE, OP_SYSTEM = 0x13, 0x33, 0x0F, 0x73

# mnemonic -> (funct3, funct7) for the R-type ALU instructions.
REG_ALU = {"add": (0, 0x00), "sub": (0, 0x20), "sll": (1, 0x00), "slt": (2, 0x00),
           "sltu": (3, 0x00), "xor": (4, 0x00), "srl": (5, 0x00), "sra": (5, 0x20),
           "or": (6, 0x00), "and": (7, 0x00)}
IMM_ALU = {"addi": 0, "slti": 2, "sltiu": 3, "xori": 4, "ori": 6, "andi": 7}
SHIFT_IMM = {"slli": (1, 0x00), "srli": (5, 0x00), "srai": (5, 0x20)}
LOADS = {"lb": 0, "lh": 1, "lw": 2, "lbu": 4, "lhu": 5}
STORES = {"sb": 0, "sh": 1, "sw": 2}
BRANCHES = {"beq": 0, "bne": 1, "blt": 4, "bge": 5, "bltu": 6, "bgeu": 7}

# Pseudo branches: name -> (real branch, operand order). "s" is the source operand
# and "t" the second one. "0" means x0.
BRANCH_ZERO = {"beqz": ("beq", "s0"), "bnez": ("bne", "s0"), "blez": ("bge", "0s"),
               "bgez": ("bge", "s0"), "bltz": ("blt", "s0"), "bgtz": ("blt", "0s")}
BRANCH_SWAP = {"bgt": "blt", "ble": "bge", "bgtu": "bltu", "bleu": "bgeu"}

PSEUDO = {"nop", "li", "la", "mv", "not", "neg", "seqz", "snez", "j", "jr", "ret", "call"}
PSEUDO |= set(BRANCH_ZERO) | set(BRANCH_SWAP)

REAL = set(REG_ALU) | set(IMM_ALU) | set(SHIFT_IMM) | set(LOADS) | set(STORES) | set(BRANCHES)
REAL |= {"lui", "auipc", "jal", "jalr", "fence", "ecall", "ebreak"}
MNEMONICS = REAL | PSEUDO

NAME_PATTERN = r"[A-Za-z_.][A-Za-z0-9_.]*"
MEMORY_PATTERN = r"^(.*?)\(\s*(\w+)\s*\)$"


class AsmError(Exception):
    """A mistake in the source, with the number of the line it is on."""

    def __init__(self, line_number, message):
        super().__init__(f"line {line_number}: {message}")
        self.line_number = line_number
        self.message = message


class Line:
    """One line of source, split into its parts."""

    def __init__(self, number, text):
        self.number = number
        self.text = text
        self.label = None
        self.name = None      # mnemonic or directive, in lower case
        self.operands = []

        code = text.split("#")[0].strip()

        label = re.match(rf"({NAME_PATTERN})\s*:(.*)", code)
        if label:
            self.label = label.group(1)
            code = label.group(2).strip()

        if code:
            parts = code.split(None, 1)
            self.name = parts[0].lower()
            if len(parts) == 2:
                self.operands = split_operands(parts[1])


def split_operands(text):
    """Split on commas that are not inside brackets, as in %lo(a,b) (not that any exist)."""
    operands, depth, current = [], 0, ""
    for char in text:
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        if char == "," and depth == 0:
            operands.append(current.strip())
            current = ""
        else:
            current += char
    operands.append(current.strip())
    return operands


# ----- Values -----

def to_signed32(value):
    value &= 0xFFFFFFFF
    return value - (1 << 32) if value & 0x80000000 else value


def hi_lo(value):
    """Split a 32-bit value so that (hi << 12) + lo == value, with lo from -2048 to 2047.
    ADDI sign-extends lo, so when bit 11 is set hi must be one larger to make up for it."""
    value &= 0xFFFFFFFF
    lo = value & 0xFFF
    if lo >= 0x800:
        lo -= 0x1000
    hi = ((value - lo) >> 12) & 0xFFFFF
    return hi, lo


def evaluate(text, symbols, line_number, here=None):
    """A number, a symbol, %hi(...), %lo(...), or terms joined by + and -."""
    text = text.strip()
    if not text:
        raise AsmError(line_number, "missing value")

    special = re.fullmatch(r"%(hi|lo)\((.*)\)", text)
    if special:
        hi, lo = hi_lo(evaluate(special.group(2), symbols, line_number, here))
        return hi if special.group(1) == "hi" else lo

    tokens = [token.strip() for token in re.split(r"([+-])", text)]
    if tokens[-1] in ("", "+", "-") and len(tokens) > 1:
        raise AsmError(line_number, f"bad value '{text}'")

    total, sign, terms = 0, 1, 0
    for token in tokens:
        if token == "-":
            sign = -sign
        elif token not in ("", "+"):
            total += sign * term_value(token, symbols, line_number, here)
            sign, terms = 1, terms + 1
    if not terms:
        raise AsmError(line_number, f"bad value '{text}'")
    return total


def term_value(text, symbols, line_number, here):
    try:
        return int(text, 0)  # base 0 follows the prefix: 10, 0x0A or 0b1010
    except ValueError:
        pass
    if text == "." and here is not None:
        return here
    if text in symbols:
        return symbols[text]
    if re.fullmatch(NAME_PATTERN, text):
        raise AsmError(line_number, f"undefined symbol '{text}'")
    raise AsmError(line_number, f"bad number '{text}'")


def check_range(value, low, high, what, line_number):
    if not low <= value <= high:
        raise AsmError(line_number, f"{what} {value} is out of range {low} to {high}")
    return value


def register(text, line_number):
    name = text.strip().lower()
    if name not in REGISTERS:
        raise AsmError(line_number, f"'{text}' is not a register")
    return REGISTERS[name]


def memory_operand(text, symbols, line_number):
    """offset(base), or (base) alone. Returns (base register, offset)."""
    match = re.match(MEMORY_PATTERN, text.strip())
    if not match:
        raise AsmError(line_number, f"'{text}' is not a memory operand like 8(sp)")
    offset_text, base = match.groups()
    offset = evaluate(offset_text, symbols, line_number) if offset_text.strip() else 0
    return register(base, line_number), check_range(offset, -2048, 2047, "offset", line_number)


# ----- The six formats -----

def r_type(funct7, rs2, rs1, funct3, rd, opcode):
    return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def i_type(imm, rs1, funct3, rd, opcode):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode


def s_type(imm, rs2, rs1, funct3, opcode):
    imm &= 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) \
        | ((imm & 0x1F) << 7) | opcode


def b_type(offset, rs2, rs1, funct3, opcode):
    """The branch offset is a multiple of 2, so bit 0 is not stored. The other bits
    are scrambled so that most of them sit where S-type keeps the same bits."""
    imm = offset & 0x1FFF
    bit = lambda n: (imm >> n) & 1  # noqa: E731
    return (bit(12) << 31) | (((imm >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) \
        | (funct3 << 12) | (((imm >> 1) & 0xF) << 8) | (bit(11) << 7) | opcode


def u_type(imm20, rd, opcode):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | opcode


def j_type(offset, rd, opcode):
    imm = offset & 0x1FFFFF
    bit = lambda n: (imm >> n) & 1  # noqa: E731
    return (bit(20) << 31) | (((imm >> 1) & 0x3FF) << 21) | (bit(11) << 20) \
        | (((imm >> 12) & 0xFF) << 12) | (rd << 7) | opcode


# ----- Pass 1: give every line an address, and fill the symbol table -----

def size_of(line, symbols):
    """How many bytes a line produces. Only li depends on a value."""
    name = line.name
    if name == ".word":
        return 4 * len(line.operands)
    if name == "la":
        return 8
    if name == "li":
        if len(line.operands) != 2:
            raise AsmError(line.number, "li takes 2 operands")
        try:
            value = evaluate(line.operands[1], symbols, line.number)
        except AsmError as error:
            raise AsmError(line.number, f"{error.message}: li can only use numbers and earlier "
                                        "symbols. Use la for a label") from None
        return len(li_words(0, value, line.number)) * 4
    return 4


def first_pass(lines):
    """Return the symbol table, and a list of (address, Line) for lines that make words."""
    symbols = {}
    used_by = {}          # word address -> number of the line that put something there
    placed = []
    address = 0

    for line in lines:
        if line.label and line.name and line.name.startswith(".") and line.name != ".word":
            raise AsmError(line.number, "a label cannot share a line with a directive")

        if line.label:
            define_symbol(symbols, line.label, address, line.number)

        if line.name is None:
            continue

        if line.name == ".org":
            if len(line.operands) != 1:
                raise AsmError(line.number, ".org takes one value")
            address = evaluate(line.operands[0], symbols, line.number)
            if address % 4 or not 0 <= address < MEMORY_BYTES:
                raise AsmError(line.number, f".org {address:#x} is not a word address in memory")
        elif line.name == ".equ":
            if len(line.operands) != 2:
                raise AsmError(line.number, ".equ takes a name and a value")
            define_symbol(symbols, line.operands[0],
                          evaluate(line.operands[1], symbols, line.number), line.number)
        elif line.name.startswith(".") and line.name != ".word":
            raise AsmError(line.number, f"unknown directive {line.name}")
        elif not line.name.startswith(".") and line.name not in MNEMONICS:
            raise AsmError(line.number, f"unknown instruction {line.name}")
        else:
            size = size_of(line, symbols)
            for word_address in range(address, address + size, 4):
                if word_address >= MEMORY_BYTES:
                    raise AsmError(line.number, f"program does not fit in {MEMORY_BYTES} bytes")
                if word_address in used_by:
                    raise AsmError(line.number, f"address {word_address:#06x} is already used "
                                                f"by line {used_by[word_address]}")
                used_by[word_address] = line.number
            placed.append((address, line))
            address += size

    return symbols, placed


def define_symbol(symbols, name, value, line_number):
    if not re.fullmatch(NAME_PATTERN, name):
        raise AsmError(line_number, f"bad symbol name '{name}'")
    if name.lower() in REGISTERS or name.lower() in MNEMONICS:
        raise AsmError(line_number, f"'{name}' is reserved and cannot be a symbol")
    if name in symbols:
        raise AsmError(line_number, f"symbol '{name}' is already defined")
    symbols[name] = value


# ----- Pass 2: turn each line into words -----

def li_words(rd, value, line_number):
    """One or two instructions that put a 32-bit value in rd."""
    check_range(value, -(1 << 31), (1 << 32) - 1, "value", line_number)
    if -2048 <= value <= 2047:
        return [i_type(value, 0, 0, rd, OP_IMM)]
    hi, lo = hi_lo(value)
    words = [u_type(hi, rd, OP_LUI)]
    if lo:
        words.append(i_type(lo, rd, 0, rd, OP_IMM))
    return words


def expect(line, count):
    if len(line.operands) != count:
        raise AsmError(line.number, f"{line.name} takes {count} operands, "
                                    f"not {len(line.operands)}")
    if not all(line.operands):
        raise AsmError(line.number, "missing operand")


def branch_offset(text, symbols, address, line_number, low, high):
    target = evaluate(text, symbols, line_number, address)
    offset = target - address
    if offset % 2:
        raise AsmError(line_number, f"target {target:#x} is not a multiple of 2")
    return check_range(offset, low, high, "jump distance", line_number)


def encode(line, address, symbols):
    """Return the words for one line."""
    name, ops, n = line.name, line.operands, line.number
    value = lambda text: evaluate(text, symbols, n, address)  # noqa: E731
    reg = lambda text: register(text, n)  # noqa: E731

    if name == ".word":
        if not ops or not all(ops):
            raise AsmError(n, ".word needs at least one value")
        return [check_range(value(text), -(1 << 31), (1 << 32) - 1, "word", n) & 0xFFFFFFFF
                for text in ops]

    if name in REG_ALU:
        expect(line, 3)
        funct3, funct7 = REG_ALU[name]
        return [r_type(funct7, reg(ops[2]), reg(ops[1]), funct3, reg(ops[0]), OP_REG)]

    if name in IMM_ALU:
        expect(line, 3)
        imm = check_range(value(ops[2]), -2048, 2047, "immediate", n)
        return [i_type(imm, reg(ops[1]), IMM_ALU[name], reg(ops[0]), OP_IMM)]

    if name in SHIFT_IMM:
        expect(line, 3)
        funct3, funct7 = SHIFT_IMM[name]
        shamt = check_range(value(ops[2]), 0, 31, "shift amount", n)
        return [i_type((funct7 << 5) | shamt, reg(ops[1]), funct3, reg(ops[0]), OP_IMM)]

    if name in LOADS:
        expect(line, 2)
        base, offset = memory_operand(ops[1], symbols, n)
        return [i_type(offset, base, LOADS[name], reg(ops[0]), OP_LOAD)]

    if name in STORES:
        expect(line, 2)
        base, offset = memory_operand(ops[1], symbols, n)
        return [s_type(offset, reg(ops[0]), base, STORES[name], OP_STORE)]

    if name in BRANCHES or name in BRANCH_ZERO or name in BRANCH_SWAP:
        if name in BRANCH_ZERO:
            expect(line, 2)
            real, order = BRANCH_ZERO[name]
            first, second = [reg(ops[0]) if c == "s" else 0 for c in order]
            target = ops[1]
        else:
            expect(line, 3)
            real = BRANCH_SWAP.get(name, name)
            first, second = reg(ops[0]), reg(ops[1])
            if name in BRANCH_SWAP:
                first, second = second, first
            target = ops[2]
        offset = branch_offset(target, symbols, address, n, -4096, 4094)
        return [b_type(offset, second, first, BRANCHES[real], OP_BRANCH)]

    if name in ("lui", "auipc"):
        expect(line, 2)
        imm = check_range(value(ops[1]), 0, 0xFFFFF, "upper immediate", n)
        return [u_type(imm, reg(ops[0]), OP_LUI if name == "lui" else OP_AUIPC)]

    if name in ("jal", "j", "call"):
        if name == "jal" and len(ops) == 2:
            rd, target = reg(ops[0]), ops[1]
        else:
            expect(line, 1)
            rd, target = (0 if name == "j" else 1), ops[0]
        offset = branch_offset(target, symbols, address, n, -(1 << 20), (1 << 20) - 2)
        return [j_type(offset, rd, OP_JAL)]

    if name == "jalr":
        if len(ops) == 1 and ops[0]:
            rd, base, offset = 1, reg(ops[0]), 0                     # jalr rs
        elif len(ops) == 2:
            rd = reg(ops[0])
            base, offset = memory_operand(ops[1], symbols, n)       # jalr rd, off(rs)
        elif len(ops) == 3:
            rd, base = reg(ops[0]), reg(ops[1])                     # jalr rd, rs, off
            offset = check_range(value(ops[2]), -2048, 2047, "offset", n)
        else:
            raise AsmError(n, "jalr takes 1 to 3 operands")
        return [i_type(offset, base, 0, rd, OP_JALR)]

    if name == "fence":
        if ops:
            raise AsmError(n, "fence takes no operands here: it always orders everything")
        return [0x0FF0000F]                                         # fence iorw, iorw
    if name in ("ecall", "ebreak"):
        expect(line, 0)
        return [0x00000073 if name == "ecall" else 0x00100073]

    # The pseudo-instructions.
    if name == "nop":
        expect(line, 0)
        return [i_type(0, 0, 0, 0, OP_IMM)]
    if name == "li":
        expect(line, 2)
        return li_words(reg(ops[0]), value(ops[1]), n)
    if name == "la":
        expect(line, 2)
        hi, lo = hi_lo(value(ops[1]) - address)
        rd = reg(ops[0])
        return [u_type(hi, rd, OP_AUIPC), i_type(lo, rd, 0, rd, OP_IMM)]
    if name in ("mv", "not", "seqz"):
        expect(line, 2)
        imm, funct3 = {"mv": (0, 0), "not": (-1, 4), "seqz": (1, 3)}[name]
        return [i_type(imm, reg(ops[1]), funct3, reg(ops[0]), OP_IMM)]
    if name == "neg":
        expect(line, 2)
        return [r_type(0x20, reg(ops[1]), 0, 0, reg(ops[0]), OP_REG)]
    if name == "snez":
        expect(line, 2)
        return [r_type(0x00, reg(ops[1]), 0, 3, reg(ops[0]), OP_REG)]
    if name == "jr":
        expect(line, 1)
        return [i_type(0, reg(ops[0]), 0, 0, OP_JALR)]
    if name == "ret":
        expect(line, 0)
        return [i_type(0, 1, 0, 0, OP_JALR)]

    raise AsmError(n, f"unknown instruction {name}")      # not reached


# ----- Putting it together -----

def assemble(source):
    """Turn source text into a list of 32-bit words from address 0, and a listing."""
    lines = [Line(number, text) for number, text in enumerate(source.splitlines(), start=1)]
    symbols, placed = first_pass(lines)

    memory = {}
    listing = []
    for address, line in placed:
        words = encode(line, address, symbols)
        for index, word in enumerate(words):
            memory[address + 4 * index] = word
        text = " ".join(f"{word:08X}" for word in words)
        listing.append(f"{address:04X}  {text:<17} {line.text.strip()}")

    size = max(memory) // 4 + 1 if memory else 0
    words = [memory.get(4 * index, 0) for index in range(size)]

    listing.append("Symbols:")
    for name, value in symbols.items():
        listing.append(f"  {name} = {value:#x}")
    return words, listing


def main():
    parser = argparse.ArgumentParser(description="Assembler for RV32I")
    parser.add_argument("source", help="input .asm file")
    parser.add_argument("output", help="output .hex file, for $readmemh")
    parser.add_argument("--list", action="store_true", help="print each address and word")
    args = parser.parse_args()

    try:
        with open(args.source) as file:
            words, listing = assemble(file.read())
    except OSError as error:
        sys.exit(f"{args.source}: {error.strerror}")
    except AsmError as error:
        sys.exit(f"{args.source}:{error.line_number}: error: {error.message}")

    with open(args.output, "w") as file:
        for word in words:
            file.write(f"{word:08X}\n")

    if args.list:
        print("\n".join(listing))


if __name__ == "__main__":
    main()
