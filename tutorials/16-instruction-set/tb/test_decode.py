import os
import random
import subprocess

import cocotb
from cocotb.triggers import Timer

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = os.path.join(HERE, "..", "build")

FLAG_VALUES = [(z, c, n, v) for z in (0, 1) for c in (0, 1) for n in (0, 1) for v in (0, 1)]

# The outputs with one bit each. A table row lists only those that are high.
SINGLE_BITS = ["alu_src_imm", "reg_we", "flags_we", "mem_read", "mem_write", "branch_taken",
               "jump", "call", "ret", "push", "pop", "jr", "halt", "illegal"]


def alu_row(alu_op):
    return {"alu_op": alu_op, "reg_we": 1, "flags_we": 1}


# What each instruction asks for, written from the spec's tables. The keys are
# output names, and "pc" says which pc_sel_ output must be the only one high.
CONTROL = {
    "NOP":     {},
    "HALT":    {"halt": 1, "pc": "hold"},
    "ADD":     alu_row(0),
    "ADC":     alu_row(1),
    "SUB":     alu_row(2),
    "SBC":     alu_row(3),
    "AND":     alu_row(4),
    "OR":      alu_row(5),
    "XOR":     alu_row(6),
    "NOT":     alu_row(7),
    "SHL":     alu_row(8),
    "SHR":     alu_row(9),
    "ASR":     alu_row(10),
    "ROL":     alu_row(11),
    "ROR":     alu_row(12),
    "MOV":     alu_row(13),
    "CMP":     {"alu_op": 2, "flags_we": 1},
    "LDI":     {"alu_op": 13, "alu_src_imm": 1, "reg_we": 1},
    "ADDI":    {"alu_op": 0, "alu_src_imm": 1, "reg_we": 1, "flags_we": 1},
    "CMPI":    {"alu_op": 2, "alu_src_imm": 1, "flags_we": 1},
    "ANDI":    {"alu_op": 4, "alu_src_imm": 1, "reg_we": 1, "flags_we": 1},
    "LD":      {"mem_read": 1, "reg_we": 1},
    "ST":      {"mem_write": 1},
    "JMP":     {"jump": 1, "pc": "imm"},
    "CALL":    {"call": 1, "mem_write": 1, "pc": "imm"},
    "RET":     {"ret": 1, "mem_read": 1, "pc": "stack"},
    "PUSH":    {"push": 1, "mem_write": 1},
    "POP":     {"pop": 1, "mem_read": 1, "reg_we": 1},
    "JR":      {"jr": 1, "pc": "rs"},
    "ILLEGAL": {"illegal": 1, "pc": "hold"},
}

# Each branch, as a rule on the flags. Bcc rows have nothing else in them.
BRANCH_RULES = {
    "BEQ": lambda z, c, n, v: z,
    "BNE": lambda z, c, n, v: not z,
    "BCS": lambda z, c, n, v: c,
    "BCC": lambda z, c, n, v: not c,
    "BMI": lambda z, c, n, v: n,
    "BPL": lambda z, c, n, v: not n,
    "BVS": lambda z, c, n, v: v,
    "BVC": lambda z, c, n, v: not v,
    "BLT": lambda z, c, n, v: n != v,
    "BGE": lambda z, c, n, v: n == v,
    "BLO": lambda z, c, n, v: not c,
    "BHS": lambda z, c, n, v: c,
}

ALL_NAMES = list(CONTROL) + list(BRANCH_RULES)
ALU_NAMES = ["ADD", "ADC", "SUB", "SBC", "AND", "OR", "XOR", "NOT", "SHL", "SHR", "ASR",
             "ROL", "ROR", "MOV", "CMP", "ILLEGAL"]
BRANCH_NAMES = list(BRANCH_RULES) + ["ILLEGAL"] * 4
OP_NAMES = {2: "LDI", 3: "ADDI", 4: "CMPI", 5: "ANDI", 6: "LD", 7: "ST", 8: "JMP", 10: "CALL",
            11: "RET", 12: "PUSH", 13: "POP", 14: "JR", 15: "ILLEGAL"}


def name_of(word):
    """The spec's name for a 16-bit word, or ILLEGAL."""
    op = word // 4096
    if op == 0:
        return {0: "NOP", 1: "HALT"}.get(word % 256, "ILLEGAL")
    if op == 1:
        return ALU_NAMES[word % 16]
    if op == 9:
        return BRANCH_NAMES[word // 256 % 16]
    return OP_NAMES[op]


def expected_outputs(name, flags):
    """Every control output for a named instruction with these flags."""
    row = {output: 0 for output in SINGLE_BITS}
    row["alu_op"] = 0
    pc = "next"

    for output, value in CONTROL.get(name, {}).items():
        if output == "pc":
            pc = value
        else:
            row[output] = value

    if name in BRANCH_RULES and BRANCH_RULES[name](*flags):
        row["branch_taken"] = 1
        pc = "imm"

    for source in ("next", "imm", "rs", "stack", "hold"):
        row["pc_sel_" + source] = int(source == pc)
    return row


async def apply(dut, word, flags):
    dut.instr.value = word
    dut.z.value, dut.c.value, dut.n.value, dut.v.value = flags
    await Timer(1, unit="ns")


def check_outputs(dut, name, flags, word):
    for output, value in expected_outputs(name, flags).items():
        assert getattr(dut, output).value == value, \
            f"{name} word={word:04x} zcnv={flags} {output} should be {value}"


def pick_word():
    """Mostly words near the legal ones, since most random imm values are illegal for op 0."""
    op = random.randrange(16)
    rest = random.getrandbits(12)
    kind = random.random()
    if op == 0 and kind < 0.7:
        rest = (rest & 0xF00) | random.randrange(2)
    return op * 4096 + rest


@cocotb.test()
async def random_words(dut):
    """Compare every output against the Python table for random words and flags."""
    seen = {name: 0 for name in ALL_NAMES}
    extra = {"taken": 0, "not_taken": 0, "illegal_op0": 0, "illegal_funct": 0,
             "illegal_cond": 0, "illegal_op15": 0, "ignored_fields": 0}

    for _ in range(20000):
        word = pick_word()
        flags = random.choice(FLAG_VALUES)
        await apply(dut, word, flags)

        name = name_of(word)
        check_outputs(dut, name, flags, word)
        assert dut.rd.value == word // 1024 % 4
        assert dut.rs.value == word // 256 % 4
        assert dut.imm.value == word % 256
        assert dut.reg_waddr.value == word // 1024 % 4

        op = word // 4096
        seen[name] += 1
        if name in BRANCH_RULES:
            taken = bool(BRANCH_RULES[name](*flags))
            extra["taken"] += taken
            extra["not_taken"] += not taken
        if name == "ILLEGAL":
            extra["illegal_op0"] += op == 0
            extra["illegal_funct"] += op == 1
            extra["illegal_cond"] += op == 9
            extra["illegal_op15"] += op == 15
        # A legal word with something in a field that this instruction does not use.
        extra["ignored_fields"] += name in ("NOP", "HALT") and word % 4096 > 1

    for name, count in {**seen, **extra}.items():
        assert count > 0, f"the random words never reached {name}"
    dut._log.info(f"{seen} {extra}")


# Every mnemonic, as a programmer would write it. Next to each is what its fields
# must hold, worked out by hand: rd, rs and imm. None means that field is not
# checked: a branch's rd and rs hold cond, which is checked by how it behaves.
PROGRAM_START = 0x10
PROGRAM_HEADER = f".equ TARGET, 0x42\n.org {PROGRAM_START}\nfirst:\n"
PROGRAM = [
    ("NOP",               0, 0, 0),
    ("HALT",              0, 0, 1),
    ("ADD R1, R2",        1, 2, 0),
    ("ADC R2, R3",        2, 3, 1),
    ("SUB R3, R0",        3, 0, 2),
    ("SBC R0, R1",        0, 1, 3),
    ("AND R1, R3",        1, 3, 4),
    ("OR R2, R0",         2, 0, 5),
    ("XOR R3, R1",        3, 1, 6),
    ("NOT R1",            1, 0, 7),
    ("SHL R2",            2, 0, 8),
    ("SHR R3",            3, 0, 9),
    ("ASR R1",            1, 0, 10),
    ("ROL R2",            2, 0, 11),
    ("ROR R3",            3, 0, 12),
    ("MOV R2, R1",        2, 1, 13),
    ("CMP R3, R2",        3, 2, 14),
    ("LDI R2, TARGET",    2, 0, 0x42),
    ("ADDI R1, -1",       1, 0, 0xFF),
    ("CMPI R3, 200",      3, 0, 200),
    ("ANDI R2, 0x0F",     2, 0, 0x0F),
    ("LD R1, [R2+4]",     1, 2, 4),
    ("ST R3, [R1+TARGET]", 3, 1, 0x42),
    ("JMP first",         0, 0, PROGRAM_START),
    ("BEQ TARGET",        None, None, 0x42),
    ("BNE first",         None, None, PROGRAM_START),
    ("BCS TARGET",        None, None, 0x42),
    ("BCC TARGET",        None, None, 0x42),
    ("BMI TARGET",        None, None, 0x42),
    ("BPL TARGET",        None, None, 0x42),
    ("BVS TARGET",        None, None, 0x42),
    ("BVC TARGET",        None, None, 0x42),
    ("BLT TARGET",        None, None, 0x42),
    ("BGE TARGET",        None, None, 0x42),
    ("BLO TARGET",        None, None, 0x42),
    ("BHS TARGET",        None, None, 0x42),
    ("CALL last",         0, 0, 0x38),
    ("RET",               0, 0, 0),
    ("PUSH R1",           0, 1, 0),
    ("POP R2",            2, 0, 0),
    ("last: JR R3",       0, 3, 0),
]


@cocotb.test()
async def assembled_program(dut):
    """Run a program through asm.py and check what decode does with each word."""
    source_path = os.path.join(BUILD, "e2e.asm")
    hex_path = os.path.join(BUILD, "e2e.hex")
    with open(source_path, "w") as file:
        file.write(PROGRAM_HEADER + "\n".join(row[0] for row in PROGRAM) + "\n")
    subprocess.run(["python3", os.path.join(HERE, "..", "tools", "asm.py"), source_path, hex_path],
                   check=True)
    with open(hex_path) as file:
        words = [int(line, 16) for line in file]
    assert len(words) == 256

    tested = set()
    for address, (line, rd, rs, imm) in enumerate(PROGRAM, start=PROGRAM_START):
        # The mnemonic comes from the source text, and never from the word.
        name = line.split(":")[-1].split()[0]
        word = words[address]
        for flags in FLAG_VALUES:
            await apply(dut, word, flags)
            check_outputs(dut, name, flags, word)
            assert dut.imm.value == imm, line
            if rd is not None:
                assert dut.rd.value == rd, line
                assert dut.rs.value == rs, line
                assert dut.reg_waddr.value == rd, line
        tested.add(name)

    assert tested == set(ALL_NAMES) - {"ILLEGAL"}, "the program does not use every mnemonic"

    # Nothing else in memory: every other word is the NOP that the assembler fills in.
    used = range(PROGRAM_START, PROGRAM_START + len(PROGRAM))
    assert all(words[a] == 0 for a in range(256) if a not in used)
    dut._log.info(f"checked {len(tested)} mnemonics from build/e2e.hex")
