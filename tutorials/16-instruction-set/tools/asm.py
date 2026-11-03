#!/usr/bin/env python3
"""Two-pass assembler for the course CPU. Python standard library only.

    python3 tools/asm.py program.asm program.hex [--list]

Pass 1 walks the source and gives every line its address. That fills the symbol
table, so pass 2 can use a label that appears later in the file. Pass 2 walks
the instructions again and turns each one into a 16-bit word.

The output is one word per line, 256 lines, ready for $readmemh. Addresses that
no instruction uses hold 0000, which is NOP. Any error stops the assembler, names
the line, and writes no output.

Source syntax:

    ; A comment runs to the end of the line.
    .equ  LIMIT, 10          ; a named constant
    .org  0x10               ; the next instruction goes at this address
    start: LDI  R0, LIMIT    ; a label is the address of what follows it
           ADDI R0, -1
           LD   R1, [R2+4]   ; also [R2], [R2-1] and [R2+LIMIT]
           BNE  start

Numbers are decimal, 0x hex or 0b binary. Mnemonics, directives and register
names may be in either case. Labels and .equ names are case sensitive. .org and
.equ run during pass 1, so they can only use numbers and earlier symbols.
"""

import argparse
import re
import sys

MEMORY_WORDS = 256

# The ALU instructions: op is 1, and these go in the low bits as funct.
TWO_REGISTER_ALU = {"ADD": 0, "ADC": 1, "SUB": 2, "SBC": 3, "AND": 4, "OR": 5,
                    "XOR": 6, "MOV": 13, "CMP": 14}
ONE_REGISTER_ALU = {"NOT": 7, "SHL": 8, "SHR": 9, "ASR": 10, "ROL": 11, "ROR": 12}

# The branches: op is 9, and these go in bits 11 to 8 as cond.
BRANCH_CONDITIONS = {"BEQ": 0, "BNE": 1, "BCS": 2, "BCC": 3, "BMI": 4, "BPL": 5,
                     "BVS": 6, "BVC": 7, "BLT": 8, "BGE": 9, "BLO": 10, "BHS": 11}

# Every instruction: mnemonic -> (op, operands, fixed bits).
# The operand words mean:
#   rd, rs   a register, which goes in that field
#   byte     a value for imm, from -128 to 255
#   address  a value for imm, from 0 to 255
#   memory   [rs+offset], which fills the rs and imm fields
INSTRUCTIONS = {
    "NOP":  (0x0, "", 0),
    "HALT": (0x0, "", 1),
    "LDI":  (0x2, "rd byte", 0),
    "ADDI": (0x3, "rd byte", 0),
    "CMPI": (0x4, "rd byte", 0),
    "ANDI": (0x5, "rd byte", 0),
    "LD":   (0x6, "rd memory", 0),
    "ST":   (0x7, "rd memory", 0),
    "JMP":  (0x8, "address", 0),
    "CALL": (0xA, "address", 0),
    "RET":  (0xB, "", 0),
    "PUSH": (0xC, "rs", 0),
    "POP":  (0xD, "rd", 0),
    "JR":   (0xE, "rs", 0),
}
for mnemonic, funct in TWO_REGISTER_ALU.items():
    INSTRUCTIONS[mnemonic] = (0x1, "rd rs", funct)
for mnemonic, funct in ONE_REGISTER_ALU.items():
    INSTRUCTIONS[mnemonic] = (0x1, "rd", funct)
for mnemonic, cond in BRANCH_CONDITIONS.items():
    INSTRUCTIONS[mnemonic] = (0x9, "address", cond << 8)

REGISTERS = {"R0": 0, "R1": 1, "R2": 2, "R3": 3}

NAME_PATTERN = r"[A-Za-z_][A-Za-z0-9_]*"
MEMORY_PATTERN = r"\[\s*(\w+)\s*(?:([+-])\s*(.+?)\s*)?\]$"


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
        self.name = None      # mnemonic or directive, in upper case
        self.operands = []

        code = text.split(";")[0].strip()

        label = re.match(rf"({NAME_PATTERN})\s*:(.*)", code)
        if label:
            self.label = label.group(1)
            code = label.group(2).strip()

        if code:
            parts = code.split(None, 1)
            self.name = parts[0].upper()
            if len(parts) == 2:
                self.operands = [operand.strip() for operand in parts[1].split(",")]


# ----- Pass 1: give every line an address, and fill the symbol table -----

def first_pass(lines):
    """Return the symbol table, and a list of (address, Line) for the instructions."""
    symbols = {}
    used_by = {}          # address -> number of the line that put an instruction there
    instructions = []
    address = 0

    for line in lines:
        if line.label and line.name and line.name.startswith("."):
            raise AsmError(line.number, "a label cannot share a line with a directive")

        if line.label:
            define_symbol(symbols, line.label, address, line.number)

        if line.name is None:
            continue

        if line.name == ".ORG":
            address = org_directive(line, symbols)
        elif line.name == ".EQU":
            equ_directive(line, symbols)
        elif line.name.startswith("."):
            raise AsmError(line.number, f"unknown directive {line.name}")
        elif line.name not in INSTRUCTIONS:
            raise AsmError(line.number, f"unknown instruction {line.name}")
        else:
            if address >= MEMORY_WORDS:
                raise AsmError(line.number, f"program does not fit in {MEMORY_WORDS} words")
            if address in used_by:
                raise AsmError(line.number,
                               f"address {address:#04x} is already used by line {used_by[address]}")
            used_by[address] = line.number
            instructions.append((address, line))
            address += 1

    return symbols, instructions


def org_directive(line, symbols):
    if len(line.operands) != 1:
        raise AsmError(line.number, ".org takes one value")
    return address_value(line.operands[0], symbols, line.number)


def equ_directive(line, symbols):
    if len(line.operands) != 2:
        raise AsmError(line.number, ".equ takes a name and a value")
    name, value = line.operands
    define_symbol(symbols, name, number_value(value, symbols, line.number), line.number)


def define_symbol(symbols, name, value, line_number):
    if not re.fullmatch(NAME_PATTERN, name):
        raise AsmError(line_number, f"bad symbol name '{name}'")
    if name.upper() in REGISTERS or name.upper() in INSTRUCTIONS:
        raise AsmError(line_number, f"'{name}' is reserved and cannot be a symbol")
    if name in symbols:
        raise AsmError(line_number, f"symbol '{name}' is already defined")
    symbols[name] = value


# ----- Pass 2: turn each instruction into a word -----

def encode(line, symbols):
    """Return the 16-bit word for one instruction."""
    op, operand_kinds, fixed_bits = INSTRUCTIONS[line.name]
    kinds = operand_kinds.split()

    if len(line.operands) != len(kinds):
        raise AsmError(line.number, f"{line.name} takes {len(kinds)} operands, "
                                    f"not {len(line.operands)}")

    word = (op << 12) | fixed_bits

    for kind, text in zip(kinds, line.operands):
        if kind == "rd":
            word |= register_value(text, line.number) << 10
        elif kind == "rs":
            word |= register_value(text, line.number) << 8
        elif kind == "byte":
            word |= byte_value(text, symbols, line.number)
        elif kind == "address":
            word |= address_value(text, symbols, line.number)
        elif kind == "memory":
            rs, offset = memory_value(text, symbols, line.number)
            word |= (rs << 8) | offset

    return word


# ----- Reading operands -----

def register_value(text, line_number):
    if text.upper() not in REGISTERS:
        raise AsmError(line_number, f"'{text}' is not a register")
    return REGISTERS[text.upper()]


def number_value(text, symbols, line_number):
    """A number or a symbol, with no range check yet."""
    try:
        return int(text, 0)  # base 0 follows the prefix: 10, 0x0A or 0b1010
    except ValueError:
        pass

    if text in symbols:
        return symbols[text]
    if re.fullmatch(NAME_PATTERN, text):
        raise AsmError(line_number, f"undefined symbol '{text}'")
    raise AsmError(line_number, f"bad number '{text}'")


def byte_value(text, symbols, line_number):
    """An 8-bit value. Negative numbers become two's complement, so -1 is 0xFF."""
    value = number_value(text, symbols, line_number)
    if not -128 <= value <= 255:
        raise AsmError(line_number, f"value {value} does not fit in 8 bits")
    return value & 0xFF


def address_value(text, symbols, line_number):
    """An address in the 256-word instruction memory. It cannot be negative."""
    value = number_value(text, symbols, line_number)
    if not 0 <= value < MEMORY_WORDS:
        raise AsmError(line_number, f"address {value} is out of range")
    return value


def memory_value(text, symbols, line_number):
    """Return (rs, imm) for [rs], [rs+value] or [rs-value]."""
    match = re.match(MEMORY_PATTERN, text)
    if not match:
        raise AsmError(line_number, f"'{text}' is not a memory operand like [R2+4]")

    register, sign, offset = match.groups()
    rs = register_value(register, line_number)
    if offset is None:
        return rs, 0
    if sign == "-":
        offset = str(-number_value(offset, symbols, line_number))
    return rs, byte_value(offset, symbols, line_number)


# ----- Putting it together -----

def assemble(source):
    """Turn source text into a list of 256 words, and return a listing as well."""
    lines = [Line(number, text) for number, text in enumerate(source.splitlines(), start=1)]

    symbols, instructions = first_pass(lines)

    words = [0] * MEMORY_WORDS
    listing = []
    for address, line in instructions:
        words[address] = encode(line, symbols)
        listing.append(f"{address:02X}  {words[address]:04X}  {line.text.strip()}")

    listing.append("Symbols:")
    for name, value in symbols.items():
        listing.append(f"  {name} = {value:#04x}")

    return words, listing


def main():
    parser = argparse.ArgumentParser(description="Assembler for the course CPU")
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
            file.write(f"{word:04X}\n")

    if args.list:
        print("\n".join(listing))


if __name__ == "__main__":
    main()
