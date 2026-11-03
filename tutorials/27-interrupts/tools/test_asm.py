#!/usr/bin/env python3
"""Tests for asm.py, run by "make asm". Every expected word was worked out by hand,
from the field layouts in the spec."""

import os
import subprocess
import sys
import unittest

import asm
import iss

BUILD = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build")

# One line for every real instruction, with the word it must give. Branches and
# jumps sit at address 0, so a target of 8 is an offset of 8.
EVERY_INSTRUCTION = [
    ("add  a0, a1, a2",     0x00C58533),
    ("sub  a0, a1, a2",     0x40C58533),
    ("sll  a0, a1, a2",     0x00C59533),
    ("slt  a0, a1, a2",     0x00C5A533),
    ("sltu a0, a1, a2",     0x00C5B533),
    ("xor  a0, a1, a2",     0x00C5C533),
    ("srl  a0, a1, a2",     0x00C5D533),
    ("sra  a0, a1, a2",     0x40C5D533),
    ("or   a0, a1, a2",     0x00C5E533),
    ("and  a0, a1, a2",     0x00C5F533),
    ("addi  a0, a1, -1",    0xFFF58513),
    ("slti  a0, a1, 5",     0x0055A513),
    ("sltiu a0, a1, -1",    0xFFF5B513),
    ("xori  a0, a1, 0x7ff", 0x7FF5C513),
    ("ori   a0, a1, -2048", 0x8005E513),
    ("andi  a0, a1, 255",   0x0FF5F513),
    ("slli  a0, a1, 31",    0x01F59513),
    ("srli  a0, a1, 1",     0x0015D513),
    ("srai  a0, a1, 3",     0x4035D513),
    ("lb   a0, 0(sp)",      0x00010503),
    ("lh   a0, 2(sp)",      0x00211503),
    ("lw   a0, 4(sp)",      0x00412503),
    ("lbu  a0, -1(sp)",     0xFFF14503),
    ("lhu  a0, 6(sp)",      0x00615503),
    ("sb   a0, 1(sp)",      0x00A100A3),
    ("sh   a0, 2(sp)",      0x00A11123),
    ("sw   a0, 8(sp)",      0x00A12423),
    ("beq  a0, a1, 8",      0x00B50463),
    ("bne  a0, a1, 8",      0x00B51463),
    ("blt  a0, a1, 8",      0x00B54463),
    ("bge  a0, a1, 8",      0x00B55463),
    ("bltu a0, a1, 8",      0x00B56463),
    ("bgeu a0, a1, 8",      0x00B57463),
    ("lui   a0, 0x12345",   0x12345537),
    ("auipc a0, 1",         0x00001517),
    ("jal  ra, 16",         0x010000EF),
    ("jalr ra, 4(a0)",      0x004500E7),
    ("fence",               0x0FF0000F),
    ("ecall",               0x00000073),
    ("ebreak",              0x00100073),
    ("csrrw  a0, mscratch, a1", 0x34059573),
    ("csrrs  a0, mstatus, a1",  0x3005A573),
    ("csrrc  a0, mie, a1",      0x3045B573),
    ("csrrwi a0, mtvec, 5",     0x3052D573),
    ("csrrsi a0, mepc, 31",     0x341FE573),
    ("csrrci a0, mcause, 1",    0x3420F573),
    ("mret",                0x30200073),
]

# The pseudo-instructions that make one word.
PSEUDO_ONE_WORD = [
    ("nop",                 0x00000013),
    ("mv   a0, a1",         0x00058513),
    ("not  a0, a1",         0xFFF5C513),
    ("neg  a0, a1",         0x40B00533),
    ("seqz a0, a1",         0x0015B513),
    ("snez a0, a1",         0x00B03533),
    ("ret",                 0x00008067),
    ("jr   t0",             0x00028067),
    ("jalr t0",             0x000280E7),
    ("j    0",              0x0000006F),
    ("jal  16",             0x010000EF),
    ("call 16",             0x010000EF),
    ("beqz a0, 8",          0x00050463),
    ("bnez a0, 8",          0x00051463),
    ("blez a0, 8",          0x00A05463),
    ("bgez a0, 8",          0x00055463),
    ("bltz a0, 8",          0x00054463),
    ("bgtz a0, 8",          0x00A04463),
    ("bgt  a0, a1, 8",      0x00A5C463),
    ("ble  a0, a1, 8",      0x00A5D463),
    ("bgtu a0, a1, 8",      0x00A5E463),
    ("bleu a0, a1, 8",      0x00A5F463),
    ("li   a0, 5",          0x00500513),
    ("li   a0, -1",         0xFFF00513),
    ("li   a0, 2047",       0x7FF00513),
    ("li   a0, 0x80000000", 0x80000537),
    ("csrr  a0, mcause",    0x34202573),
    ("csrw  mtvec, t0",     0x30529073),
    ("csrs  mstatus, t0",   0x3002A073),
    ("csrc  mstatus, t0",   0x3002B073),
    ("csrwi mscratch, 0",   0x34005073),
    ("csrsi mstatus, 8",    0x30046073),
    ("csrci mstatus, 8",    0x30047073),
]

# li and la, which can make two words.
PSEUDO_TWO_WORDS = [
    ("li a0, 0x12345678",   [0x12345537, 0x67850513]),
    ("li a0, 0x12345FFF",   [0x12346537, 0xFFF50513]),   # %lo is -1, so %hi rounds up
    ("li a0, 2048",         [0x00001537, 0x80050513]),
    ("li a0, -2049",        [0xFFFFF537, 0x7FF50513]),
    ("la a0, there\n.org 0x10\nthere: nop", [0x00000517, 0x01050513]),
]

# Spellings of operands that the tables above do not reach.
OTHER_FORMS = [
    ("add x10, x11, x12",            0x00C58533),
    ("ADD A0, A1, A2",               0x00C58533),
    ("addi s0, fp, 0",               0x00040413),
    ("lw a0, (sp)",                  0x00012503),
    ("sw a0, -4(sp)",                0xFEA12E23),
    ("lw a0, %lo(0x800)(a1)",        0x8005A503),
    ("lui a0, %hi(0x12345FFF)",      0x12346537),
    ("addi a0, a0, %lo(0x12345FFF)", 0xFFF50513),
    ("jalr a0, a1, -8",              0xFF858567),
    ("addi a0, a0, 3-4",             0xFFF50513),
    ("li a0, 0b1010",                0x00A00513),
    ("csrr a0, 0xC00",               0xC0002573),
    ("csrrs a0, MIP, x0",            0x34402573),
]


def words_of(source):
    return asm.assemble(source)[0]


class Encoding(unittest.TestCase):
    def test_every_instruction(self):
        for line, word in EVERY_INSTRUCTION:
            with self.subTest(line):
                self.assertEqual(words_of(line)[0], word)

    def test_the_table_is_complete(self):
        tested = {line.split()[0] for line, _ in EVERY_INSTRUCTION}
        self.assertEqual(tested, asm.REAL)
        self.assertEqual(len(tested), 47)

    def test_pseudo_instructions(self):
        for line, word in PSEUDO_ONE_WORD:
            with self.subTest(line):
                self.assertEqual(words_of(line), [word])
        for line, words in PSEUDO_TWO_WORDS:
            with self.subTest(line):
                self.assertEqual(words_of(line)[:2], words)
        tested = {line.split()[0] for line, _ in PSEUDO_ONE_WORD + PSEUDO_TWO_WORDS}
        self.assertEqual(tested - {"jalr", "jal"}, asm.PSEUDO)

    def test_other_forms(self):
        for line, word in OTHER_FORMS:
            with self.subTest(line):
                self.assertEqual(words_of(line)[0], word)

    def test_the_model_reads_each_word_as_the_same_instruction(self):
        """iss.py decodes on its own. Two independent readings must agree."""
        for line, word in EVERY_INSTRUCTION:
            with self.subTest(line):
                self.assertEqual(iss.mnemonic(word), line.split()[0].upper())


class Offsets(unittest.TestCase):
    def test_a_branch_backwards(self):
        words = words_of("back: nop\nnop\nnop\nnop\nbeq a0, a1, back\n")
        self.assertEqual(words[4], 0xFEB508E3)       # offset -16

    def test_a_jump_backwards(self):
        self.assertEqual(words_of("top: nop\nj top\n")[1], 0xFFDFF06F)   # offset -4

    def test_the_longest_branches(self):
        words = words_of("beq a0, a1, far\n.org 0xFFC\nfar: nop\n")
        self.assertEqual(words[0], 0x7EB50EE3)       # +4092
        words = words_of(".org 0x1000\nbeq a0, a1, 0\n")
        self.assertEqual(words[0x400], 0x80B50063)   # -4096

    def test_dot_is_this_address(self):
        self.assertEqual(words_of("nop\nj .\n")[1], 0x0000006F)

    def test_labels_are_case_sensitive(self):
        words = words_of("Loop: nop\nloop: nop\nj loop\n")
        self.assertEqual(words[2], 0xFFDFF06F)

    def test_org_leaves_a_gap_of_zeros(self):
        words = words_of("ebreak\n.org 0x10\nnop\n")
        self.assertEqual(words, [0x00100073, 0, 0, 0, 0x13])

    def test_word_directive(self):
        words = words_of("j end\ndata: .word 1, -1, data\nend: nop\n")
        self.assertEqual(words, [0x0100006F, 1, 0xFFFFFFFF, 4, 0x13])

    def test_equ(self):
        self.assertEqual(words_of(".equ N, 7\n.equ M, N+1\naddi a0, a0, M\n")[0], 0x00850513)

    def test_an_empty_program_is_empty(self):
        self.assertEqual(words_of("# nothing\n"), [])


# Source, the line the error must name, and a part of its message.
ERRORS = [
    ("foo a0",                   1, "unknown instruction foo"),
    (".byte 1",                  1, "unknown directive .byte"),
    ("start: .org 0x10",         1, "cannot share a line"),
    ("add a0, a1",               1, "add takes 3 operands, not 2"),
    ("add a0, a1,",              1, "missing operand"),
    ("ecall a0",                 1, "ecall takes 0 operands, not 1"),
    ("add a0, a1, x32",          1, "'x32' is not a register"),
    ("add a0, a1, r1",           1, "'r1' is not a register"),
    ("addi a0, a0, 2048",        1, "immediate 2048 is out of range"),
    ("addi a0, a0, -2049",       1, "immediate -2049 is out of range"),
    ("slli a0, a0, 32",          1, "shift amount 32 is out of range"),
    ("lw a0, 2048(sp)",          1, "offset 2048 is out of range"),
    ("lw a0, sp",                1, "not a memory operand"),
    ("lw a0, 4(q9)",             1, "'q9' is not a register"),
    ("lui a0, 0x100000",         1, "upper immediate 1048576 is out of range"),
    ("lui a0, -1",               1, "upper immediate -1 is out of range"),
    ("beq a0, a1, 3",            1, "not a multiple of 2"),
    ("beq a0, a1, 4096",         1, "jump distance 4096 is out of range"),
    ("jal ra, 0x100000",         1, "jump distance 1048576 is out of range"),
    ("j nowhere",                1, "undefined symbol 'nowhere'"),
    ("li a0, later\nlater: nop", 1, "li can only use numbers and earlier symbols"),
    ("li a0, 0x100000000",       1, "value 4294967296 is out of range"),
    ("addi a0, a0, 12z",         1, "bad number '12z'"),
    ("addi a0, a0, 1+",          1, "bad value '1+'"),
    (".org 2",                   1, "is not a word address"),
    (".org 0x10000",             1, "is not a word address"),
    (".org 0xFFFC\nnop\nnop",    3, "does not fit in 65536 bytes"),
    (".org 4\nnop\n.org 4\nnop", 4, "address 0x0004 is already used by line 2"),
    ("a: nop\na: nop",           2, "symbol 'a' is already defined"),
    ("sp: nop",                  1, "'sp' is reserved"),
    ("add: nop",                 1, "'add' is reserved"),
    (".equ A",                   1, ".equ takes a name and a value"),
    ("fence rw, rw",             1, "fence takes no operands"),
    ("jalr a0, a1, 1, 2",        1, "jalr takes 1 to 3 operands"),
    ("csrrwi a0, mtvec, 32",     1, "immediate 32 is out of range 0 to 31"),
    ("csrr a0, 0x1000",          1, "CSR number 4096 is out of range"),
    ("csrr a0, nosuch",          1, "undefined symbol 'nosuch'"),
    ("csrw mtvec",               1, "csrw takes 2 operands, not 1"),
]


class Errors(unittest.TestCase):
    def test_every_error(self):
        for source, line_number, message in ERRORS:
            with self.subTest(source):
                with self.assertRaises(asm.AsmError) as caught:
                    asm.assemble(source)
                self.assertEqual(caught.exception.line_number, line_number)
                self.assertIn(message, caught.exception.message)


class CommandLine(unittest.TestCase):
    """Runs asm.py the way the Makefile does."""

    def run_asm(self, source):
        os.makedirs(BUILD, exist_ok=True)
        source_path = os.path.join(BUILD, "test_asm.asm")
        hex_path = os.path.join(BUILD, "test_asm.hex")
        with open(hex_path, "w") as file:
            file.write("old\n")
        with open(source_path, "w") as file:
            file.write(source)
        script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "asm.py")
        result = subprocess.run([sys.executable, script, source_path, hex_path],
                                capture_output=True, text=True)
        with open(hex_path) as file:
            return result, file.read().split("\n")

    def test_good_source(self):
        result, lines = self.run_asm("li a0, 1\nebreak\n")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(lines, ["00100513", "00100073", ""])

    def test_an_error_names_the_line_and_writes_nothing(self):
        result, lines = self.run_asm("nop\nj nowhere\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn(":2: error: undefined symbol 'nowhere'", result.stderr)
        self.assertEqual(lines[0], "old")


if __name__ == "__main__":
    unittest.main()
