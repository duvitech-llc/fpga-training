import os
import random
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
import asm  # noqa: E402

PROGRAMS = 300
TIMEOUT = 20000
STACK_TOP = 0xF0

TWO_REG = ["ADD", "ADC", "SUB", "SBC", "AND", "OR", "XOR", "MOV", "CMP"]
ONE_REG = ["NOT", "SHL", "SHR", "ASR", "ROL", "ROR"]
BRANCHES = ["BEQ", "BNE", "BCS", "BCC", "BMI", "BPL", "BVS", "BVC", "BLT", "BGE", "BLO", "BHS"]

# Bits each op ignores, which get random junk now and then. Spec: "the hardware
# ignores unused fields".
UNUSED_BITS = {0x0: 0x0F00, 0x2: 0x0300, 0x3: 0x0300, 0x4: 0x0300, 0x5: 0x0300, 0x8: 0x0F00,
               0xA: 0x0F00, 0xB: 0x0FFF, 0xC: 0x0CFF, 0xD: 0x03FF, 0xE: 0x0CFF}

# Every class that must have run, or the test fails.
CLASSES = TWO_REG + ONE_REG + ["NOP", "HALT", "LDI", "ADDI", "CMPI", "ANDI", "LD", "ST", "JMP",
                               "CALL", "RET", "PUSH", "POP", "JR", "PUSH_R3", "POP_R3"] + \
    [name + "_taken" for name in BRANCHES] + [name + "_not_taken" for name in BRANCHES]


class Model:
    """A small model: it runs a list of words and gives the final state."""

    def __init__(self, words):
        self.words = words
        self.regs = [0, 0, 0, 0]
        self.z = self.c = self.n = self.v = 0
        self.pc = 0
        self.mem = [0] * 256
        self.counts = {}

    def count(self, name):
        self.counts[name] = self.counts.get(name, 0) + 1

    def set_zn(self, y):
        self.z = int(y == 0)
        self.n = y >> 7

    def add(self, a, b, carry):
        total = a + b + carry
        y = total & 0xFF
        self.c = total >> 8
        self.v = int((a >> 7) == (b >> 7) and (y >> 7) != (a >> 7))
        self.set_zn(y)
        return y

    def alu(self, funct, a, b):
        cin = self.c
        if funct == 0:
            return self.add(a, b, 0)
        if funct == 1:
            return self.add(a, b, cin)
        if funct == 2:
            return self.add(a, b ^ 0xFF, 1)
        if funct == 3:
            return self.add(a, b ^ 0xFF, cin)
        if funct in (8, 11):                                  # SHL, ROL
            y = ((a << 1) | (cin if funct == 11 else 0)) & 0xFF
            self.c, self.v = a >> 7, int((a >> 7) != ((a >> 6) & 1))
        elif funct in (9, 10, 12):                            # SHR, ASR, ROR
            top = {9: 0, 10: a >> 7, 12: cin}[funct]
            y = (a >> 1) | (top << 7)
            self.c, self.v = a & 1, 0
        else:
            y = {4: a & b, 5: a | b, 6: a ^ b, 7: a ^ 0xFF, 13: b}[funct]
            self.c, self.v = 0, 0
        self.set_zn(y)
        return y

    def taken(self, cond):
        z, c, n, v = self.z, self.c, self.n, self.v
        return bool([z, not z, c, not c, n, not n, v, not v, n != v, n == v, not c, c][cond])

    def push(self, value):
        self.regs[3] = (self.regs[3] - 1) & 0xFF
        self.mem[self.regs[3]] = value

    def pop(self):
        value = self.mem[self.regs[3]]
        self.regs[3] = (self.regs[3] + 1) & 0xFF
        return value

    def step(self):
        """Runs one instruction. Returns False when it was HALT."""
        word = self.words[self.pc]
        op, rd, rs, imm = word >> 12, (word >> 10) & 3, (word >> 8) & 3, word & 0xFF
        regs = self.regs
        next_pc = (self.pc + 1) & 0xFF

        if op == 0x0:
            self.count("HALT" if imm else "NOP")
            if imm:
                return False
        elif op == 0x1:
            funct = imm & 15
            names = {**asm.TWO_REGISTER_ALU, **asm.ONE_REGISTER_ALU}
            self.count(next(name for name, code in names.items() if code == funct))
            if funct == 14:
                self.alu(2, regs[rd], regs[rs])
            else:
                regs[rd] = self.alu(funct, regs[rd], regs[rs])
        elif op == 0x2:
            self.count("LDI")
            regs[rd] = imm
        elif op == 0x3:
            self.count("ADDI")
            regs[rd] = self.alu(0, regs[rd], imm)
        elif op == 0x4:
            self.count("CMPI")
            self.alu(2, regs[rd], imm)
        elif op == 0x5:
            self.count("ANDI")
            regs[rd] = self.alu(4, regs[rd], imm)
        elif op == 0x6:
            self.count("LD")
            regs[rd] = self.mem[(regs[rs] + imm) & 0xFF]
        elif op == 0x7:
            self.count("ST")
            self.mem[(regs[rs] + imm) & 0xFF] = regs[rd]
        elif op == 0x8:
            self.count("JMP")
            next_pc = imm
        elif op == 0x9:
            cond = (word >> 8) & 15
            taken = self.taken(cond)
            self.count(BRANCHES[cond] + ("_taken" if taken else "_not_taken"))
            if taken:
                next_pc = imm
        elif op == 0xA:
            self.count("CALL")
            self.push(next_pc)
            next_pc = imm
        elif op == 0xB:
            self.count("RET")
            next_pc = self.pop()
        elif op == 0xC:
            self.count("PUSH_R3" if rs == 3 else "PUSH")
            self.push(regs[rs])
        elif op == 0xD:
            self.count("POP_R3" if rd == 3 else "POP")
            value = self.pop()
            regs[rd] = value
        elif op == 0xE:
            self.count("JR")
            next_pc = regs[rs]
        else:
            raise AssertionError(f"the generator made an illegal word {word:04X}")

        self.pc = next_pc
        return True

    def run(self):
        for retired in range(1, TIMEOUT):
            if not self.step():
                return retired
        raise AssertionError("the program in the model did not stop")


def simple(rng):
    """One instruction that cannot change the flow, the stack pointer or the stack."""
    rd = rng.randrange(3)        # never R3, which holds the stack pointer
    rs = rng.randrange(4)
    kind = rng.randrange(7)
    if kind == 0:
        return [f"{rng.choice(TWO_REG)} R{rd}, R{rs}"]
    if kind == 1:
        return [f"{rng.choice(ONE_REG)} R{rd}"]
    if kind == 2:
        return [f"LDI R{rd}, {rng.randrange(256)}"]
    if kind == 3:
        return [f"{rng.choice(['ADDI', 'CMPI', 'ANDI'])} R{rd}, {rng.randrange(256)}"]
    if kind == 4:
        return ["NOP"]
    # Addresses come from a calculated register, kept below the stack at 0xC0.
    base = rng.randrange(3)
    mask = f"ANDI R{base}, 0x7F"
    offset = rng.randrange(0x40)
    if kind == 5:
        return [mask, f"LD R{rd}, [R{base}+{offset}]"]
    return [mask, f"ST R{rd}, [R{base}+{offset}]"]


def generate(rng, length=70):
    """Random source text. It always reaches HALT, without touching an illegal word:
    branches and jumps only go forward, and each CALL returns."""
    labels = iter(range(10000))
    subs = [f"sub{n}" for n in range(3)]
    lines = [f"LDI R3, {STACK_TOP}"]

    for _ in range(length):
        kind = rng.randrange(10)
        if kind <= 3:
            lines += simple(rng)
        elif kind == 4:                      # a forward branch, over a few instructions
            label = f"skip{next(labels)}"
            lines += simple(rng)
            lines.append(f"{rng.choice(BRANCHES)} {label}")
            for _ in range(rng.randrange(1, 4)):
                lines += simple(rng)
            lines.append(f"{label}:")
        elif kind == 5:                      # JMP or JR, forward
            label = f"skip{next(labels)}"
            if rng.random() < 0.5:
                lines.append(f"JMP {label}")
            else:
                reg = rng.randrange(3)
                lines += [f"LDI R{reg}, {label}", f"JR R{reg}"]
            lines += simple(rng)
            lines.append(f"{label}:")
        elif kind == 6:
            lines.append(f"CALL {rng.choice(subs)}")
        elif kind == 7:                      # PUSH and POP, balanced
            lines.append(f"PUSH R{rng.randrange(3)}")
            lines += simple(rng)
            lines.append(f"POP R{rng.randrange(3)}")
        elif kind == 8:                      # PUSH R3 stores the old R3
            lines += ["PUSH R3", f"POP R{rng.randrange(3)}"]
        else:                                # POP R3 keeps the loaded value
            reg = rng.randrange(3)
            lines += [f"PUSH R{reg}", "POP R3", f"MOV R{reg}, R3", f"LDI R3, {STACK_TOP}"]

    lines.append("HALT")

    for sub in subs:
        lines.append(f"{sub}:")
        reg = rng.randrange(3)
        lines.append(f"PUSH R{reg}")
        for _ in range(rng.randrange(1, 4)):
            lines += simple(rng)
        lines += [f"POP R{reg}", "RET"]

    return "\n".join(lines)


def add_junk(rng, words):
    """Fills the fields that each instruction ignores, in about a third of them."""
    result = []
    for word in words:
        op = word >> 12
        if rng.random() < 0.33 and op in UNUSED_BITS:
            word |= rng.randrange(0x10000) & UNUSED_BITS[op]
        elif rng.random() < 0.33 and op == 0x1:
            word |= rng.randrange(16) << 4            # the top of imm, above funct
        result.append(word)
    return result


async def run_on_cpu(dut, words):
    """Loads a program, resets, and returns how many instructions retired."""
    dut.rst.value = 1
    for address in range(256):
        dut.imem[address].value = words[address]
        dut.dmem[address].value = 0
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst.value = 0

    retired = 0
    for _ in range(TIMEOUT):
        await FallingEdge(dut.clk)
        retired += int(dut.retire.value)
        if int(dut.halted.value):
            break
    else:
        raise AssertionError("the CPU did not halt")

    # Halted means halted: it stays high, and nothing more retires.
    for _ in range(4):
        await FallingEdge(dut.clk)
        retired += int(dut.retire.value)
        assert int(dut.halted.value), "the CPU left halted without a reset"
    return retired


@cocotb.test()
async def random_programs(dut):
    """Random programs: final registers, flags, PC and memory against the model."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())

    rng = random.Random(cocotb.RANDOM_SEED)
    counts = {}
    instructions = 0

    for number in range(PROGRAMS):
        source = generate(rng)
        words, _ = asm.assemble(source)
        words = add_junk(rng, words)

        model = Model(words)
        expected_retired = model.run()
        for name, value in model.counts.items():
            counts[name] = counts.get(name, 0) + value

        retired = await run_on_cpu(dut, words)
        instructions += retired

        cpu = dut.u_cpu
        regs = [int(cpu.u_regfile.q[n].value) for n in range(4)]
        flags = [int(s.value) for s in (cpu.flag_z, cpu.flag_c, cpu.flag_n, cpu.flag_v)]
        state = f"program {number}\n{source}"

        assert retired == expected_retired, f"retired {retired}, not {expected_retired}, {state}"
        assert regs == model.regs, f"registers {regs}, not {model.regs}, {state}"
        assert flags == [model.z, model.c, model.n, model.v], f"flags {flags}, {state}"
        assert int(cpu.pc.value) == model.pc, f"pc, {state}"
        assert int(dut.illegal.value) == 0, state
        for address in range(256):
            value = int(dut.dmem[address].value)
            assert value == model.mem[address], f"memory at {address:#04x}, {state}"

    missing = [name for name in CLASSES if counts.get(name, 0) == 0]
    assert not missing, f"never executed: {missing}"
    rarest = min(CLASSES, key=lambda name: counts[name])
    dut._log.info(f"{PROGRAMS} programs, {instructions} instructions, {len(CLASSES)} classes, "
                  f"rarest was {rarest} with {counts[rarest]}")
