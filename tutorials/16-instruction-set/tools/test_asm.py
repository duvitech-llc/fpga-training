#!/usr/bin/env python3
"""Tests for asm.py, run by "make asm". Every expected word was worked out by hand."""

import os
import subprocess
import sys
import unittest

import asm

BUILD = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build")

# One line for every mnemonic, with the word it must give.
EVERY_MNEMONIC = [
    ("NOP",               0x0000),
    ("HALT",              0x0001),
    ("ADD R1, R2",        0x1600),
    ("ADC R0, R3",        0x1301),
    ("SUB R2, R1",        0x1902),
    ("SBC R3, R0",        0x1C03),
    ("AND R1, R1",        0x1504),
    ("OR  R2, R3",        0x1B05),
    ("XOR R0, R1",        0x1106),
    ("NOT R2",            0x1807),
    ("SHL R1",            0x1408),
    ("SHR R3",            0x1C09),
    ("ASR R0",            0x100A),
    ("ROL R1",            0x140B),
    ("ROR R2",            0x180C),
    ("MOV R3, R2",        0x1E0D),
    ("CMP R1, R2",        0x160E),
    ("LDI R1, 0x42",      0x2442),
    ("ADDI R2, 255",      0x38FF),
    ("CMPI R3, 10",       0x4C0A),
    ("ANDI R0, 0x0F",     0x500F),
    ("LD R1, [R2+4]",     0x6604),
    ("ST R3, [R1+0x10]",  0x7D10),
    ("JMP 0x20",          0x8020),
    ("BEQ 0x20",          0x9020),
    ("BNE 0x20",          0x9120),
    ("BCS 0x20",          0x9220),
    ("BCC 0x20",          0x9320),
    ("BMI 0x20",          0x9420),
    ("BPL 0x20",          0x9520),
    ("BVS 0x20",          0x9620),
    ("BVC 0x20",          0x9720),
    ("BLT 0x20",          0x9820),
    ("BGE 0x20",          0x9920),
    ("BLO 0x20",          0x9A20),
    ("BHS 0x20",          0x9B20),
    ("CALL 0x30",         0xA030),
    ("RET",               0xB000),
    ("PUSH R2",           0xC200),
    ("POP R1",            0xD400),
    ("JR R3",             0xE300),
]

# Spellings of operands that the table above does not reach.
OTHER_FORMS = [
    ("ADDI R2, -1",       0x38FF),
    ("LDI R0, -128",      0x2080),
    ("LDI R0, 0b1010",    0x200A),
    ("LD R1, [R2]",       0x6600),
    ("LD R0, [R3-1]",     0x63FF),
    ("ST R0, [R1 + 2]",   0x7102),
    ("ld r1, [r2+4]",     0x6604),
    ("Add r1, R2",        0x1600),
    ("JMP 255",           0x80FF),
]

# Source, the line the error must name, and a part of its message.
ERRORS = [
    ("FOO R1",                       1, "unknown instruction FOO"),
    ("1abc: NOP",                    1, "unknown instruction 1ABC:"),
    (".byte 1",                      1, "unknown directive .BYTE"),
    ("start: .org 0x10",             1, "cannot share a line"),
    ("x: .equ A, 1",                 1, "cannot share a line"),
    ("NOP 1",                        1, "takes 0 operands, not 1"),
    ("ADD R1",                       1, "takes 2 operands, not 1"),
    ("NOT R1, R2",                   1, "takes 1 operands, not 2"),
    ("LDI R0, 1, 2",                 1, "takes 2 operands, not 3"),
    ("JMP",                          1, "takes 1 operands, not 0"),
    ("ADD R1, R4",                   1, "'R4' is not a register"),
    ("PUSH 3",                       1, "'3' is not a register"),
    ("POP X",                        1, "'X' is not a register"),
    ("LDI R0, 256",                  1, "value 256 does not fit"),
    ("LDI R0, -129",                 1, "value -129 does not fit"),
    ("LD R0, [R1+256]",              1, "value 256 does not fit"),
    ("LD R0, [R1-129]",              1, "value -129 does not fit"),
    (".equ BIG, 300\nADDI R0, BIG",  2, "value 300 does not fit"),
    ("JMP 256",                      1, "address 256 is out of range"),
    ("BEQ -1",                       1, "address -1 is out of range"),
    ("CALL 0x100",                   1, "address 256 is out of range"),
    (".org 255\nNOP\nend:\nJMP 0",   4, "does not fit in 256 words"),
    (".org 255\nNOP\nend:\n.org 0\nJMP end", 5, "address 256 is out of range"),
    ("NOP\nJMP nowhere",             2, "undefined symbol 'nowhere'"),
    ("BNE nowhere",                  1, "undefined symbol 'nowhere'"),
    ("CALL nowhere",                 1, "undefined symbol 'nowhere'"),
    ("LDI R0, nowhere",              1, "undefined symbol 'nowhere'"),
    ("LD R0, [R1+nowhere]",          1, "undefined symbol 'nowhere'"),
    ("LD R0, [R1-nowhere]",          1, "undefined symbol 'nowhere'"),
    (".org later\nlater: NOP",       1, "undefined symbol 'later'"),
    (".equ A, later\nlater: NOP",    1, "undefined symbol 'later'"),
    ("a: NOP\na: NOP",               2, "symbol 'a' is already defined"),
    (".equ a, 1\n.equ a, 2",         2, "symbol 'a' is already defined"),
    ("a: NOP\n.equ a, 2",            2, "symbol 'a' is already defined"),
    ("r1: NOP",                      1, "'r1' is reserved"),
    ("add: NOP",                     1, "'add' is reserved"),
    (".equ R0, 1",                   1, "'R0' is reserved"),
    (".equ 1x, 3",                   1, "bad symbol name '1x'"),
    ("LDI R0, 12z",                  1, "bad number '12z'"),
    ("LDI R0, 010",                  1, "bad number '010'"),
    ("LDI R0,",                      1, "bad number ''"),
    ("LD R0, R1",                    1, "not a memory operand"),
    ("LD R0, [R1",                   1, "not a memory operand"),
    ("LD R0, [R1*2]",                1, "not a memory operand"),
    ("LD R0, [R4]",                  1, "'R4' is not a register"),
    (".org",                         1, ".org takes one value"),
    (".org 1, 2",                    1, ".org takes one value"),
    (".org 256",                     1, "address 256 is out of range"),
    (".equ A",                       1, ".equ takes a name and a value"),
    (".equ A, 1, 2",                 1, ".equ takes a name and a value"),
    (".org 4\nNOP\n.org 4\nHALT",    4, "address 0x04 is already used by line 2"),
    (".org 255\nNOP\nNOP",           3, "does not fit in 256 words"),
]


def first_word(line):
    return asm.assemble(line)[0][0]


class Encoding(unittest.TestCase):
    def test_every_mnemonic(self):
        for line, word in EVERY_MNEMONIC:
            with self.subTest(line):
                self.assertEqual(first_word(line), word)

    def test_the_table_is_complete(self):
        tested = {line.split()[0].upper() for line, _ in EVERY_MNEMONIC}
        self.assertEqual(tested, set(asm.INSTRUCTIONS))
        self.assertEqual(len(tested), 41)

    def test_other_forms(self):
        for line, word in OTHER_FORMS:
            with self.subTest(line):
                self.assertEqual(first_word(line), word)


class Symbols(unittest.TestCase):
    def test_forward_and_backward_labels(self):
        words, _ = asm.assemble("back: NOP\n  JMP ahead\n  JMP back\nahead:\n  HALT\n")
        self.assertEqual(words[:4], [0x0000, 0x8003, 0x8000, 0x0001])

    def test_comments_and_blank_lines_do_not_use_addresses(self):
        words, _ = asm.assemble("; a comment\n\n   HALT ; another\n")
        self.assertEqual(words[0], 0x0001)

    def test_equ(self):
        words, _ = asm.assemble(".equ TOP, 0xF0\n.equ ALSO, TOP\nLDI R3, ALSO\n")
        self.assertEqual(words[0], 0x2CF0)

    def test_equ_in_memory_offset(self):
        words, _ = asm.assemble(".equ OFF, 3\nLD R0, [R1+OFF]\nLD R0, [R1-OFF]\n")
        self.assertEqual(words[:2], [0x6103, 0x61FD])

    def test_labels_are_case_sensitive(self):
        words, _ = asm.assemble("Loop: NOP\nloop: NOP\nJMP loop\n")
        self.assertEqual(words[2], 0x8001)

    def test_org_leaves_a_gap_of_nops(self):
        words, _ = asm.assemble("HALT\n.org 0x10\nhere: JMP here\n")
        self.assertEqual(words[0], 0x0001)
        self.assertEqual(words[1:0x10], [0] * 15)
        self.assertEqual(words[0x10], 0x8010)

    def test_org_can_go_backwards_without_overlap(self):
        words, _ = asm.assemble(".org 2\nHALT\n.org 0\nNOP\nNOP\n")
        self.assertEqual(words[:3], [0, 0, 1])

    def test_the_last_address_is_usable(self):
        words, _ = asm.assemble(".org 255\nend: JMP end\n")
        self.assertEqual(words[255], 0x80FF)

    def test_an_empty_program_is_all_nops(self):
        self.assertEqual(asm.assemble("")[0], [0] * 256)


class Errors(unittest.TestCase):
    def test_every_error(self):
        for source, line_number, message in ERRORS:
            with self.subTest(source):
                with self.assertRaises(asm.AsmError) as caught:
                    asm.assemble(source)
                self.assertEqual(caught.exception.line_number, line_number)
                self.assertIn(message, caught.exception.message)


class CommandLine(unittest.TestCase):
    """Runs asm.py the way a Makefile does."""

    def run_asm(self, source):
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

    def test_good_source_gives_256_lines(self):
        result, lines = self.run_asm("LDI R3, 0xF0\nHALT\n")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(lines[:3], ["2CF0", "0001", "0000"])
        self.assertEqual(len(lines), 257)  # the last is the empty string after the final \n

    def test_an_error_names_the_line_and_writes_nothing(self):
        result, lines = self.run_asm("NOP\nJMP nowhere\n")
        self.assertEqual(result.returncode, 1)
        self.assertIn(":2: error: undefined symbol 'nowhere'", result.stderr)
        self.assertEqual(lines[0], "old")

    def test_a_missing_file_is_a_short_message(self):
        result = subprocess.run([sys.executable, asm.__file__, "no_such.asm", "x.hex"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("no_such.asm", result.stderr)
        self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
