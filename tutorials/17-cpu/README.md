# Tutorial 17: The CPU

Everything in this course has been heading here. A FIFO moves data when told to, but a
CPU reads its own orders from a memory, so one piece of hardware can do any job you can
write down. This tutorial joins the parts you have already built into a working 8-bit
CPU, and runs real programs on it, including recursion. Tutorial 18 then checks it
properly, Tutorial 19 connects it to the world, and Tutorial 20 makes it faster.

Finish [Tutorial 16](../16-instruction-set/README.md) first, since it defines what this
CPU must do. The FSM style comes from [Tutorial 5](../05-sequence-detector/README.md),
and the memories behave as in [Tutorial 6](../06-sync-ram/README.md). Run these commands
in a VS Code terminal, from this directory:

```bash
cd tutorials/17-cpu
```

To run everything at once, use `make all`.

## Datapath and control

A CPU has two halves, and keeping them apart is what makes it easy to understand.

The **datapath** holds and moves data. It has the program counter, an instruction
register, the register file from [Tutorial 11](../11-register-file/README.md), the ALU
from [Tutorial 12](../12-flags-alu/README.md), four flags, and a register called
`result` that carries a value from one step to a later one. It never decides anything.

The **control** decides. It is an FSM, and on each clock it says which datapath registers
load. In [`rtl/cpu.v`](rtl/cpu.v) every datapath register is an `enreg` from Tutorial 11,
so "load" is simply its `en` input, and nearly all of the control is one line each:

```verilog
wire ir_load     = (state == S_WAIT);
wire flags_load  = (state == S_EXECUTE) && flags_we;
wire pc_load     = (state == S_RETIRE);
```

```text
                 +-------------------- imm --------------------+
                 |                                             |
 imem_data --> [ ir ] --> decode --> tells the FSM what this   |
                 |                   instruction needs         |
                 | rd, rs                                      v
                 v                                          +-----+
            +---------+ port a (rd, or R3 for the stack) -->| ALU |--> [ flags ]
            | regfile |                                     |     |
            |  R0-R3  | port b (rs) --------------+-------->|     |
            +---------+                           |         +-----+
                 ^                                |            |
                 |                                v            v
                 +------ result <---- dmem_rdata, or what EXECUTE picked
                           |
                           +--> dmem_wdata, and the PC for RET
```

The memories are outside the module, on the ports in the spec.
[`rtl/cpu_top.v`](rtl/cpu_top.v) adds them, using `$readmemh` for a program. It reads
`imem` on every clock, since an instruction memory has nothing else to do.

## The fetch, decode, execute cycle

Each instruction is one trip round the FSM, and the trip depends on the instruction:

| Code | State       | What happens on this clock                                |
| ---- | ----------- | --------------------------------------------------------- |
| 0    | `FETCH`     | `pc` is on `imem_addr`, and the memory takes it at the edge |
| 1    | `WAIT`      | `imem_data` is valid, and `ir` loads it                   |
| 2    | `DECODE`    | `decode` reads `ir`, and the FSM picks the route          |
| 3    | `EXECUTE`   | The ALU works. `result` loads, and the flags if needed    |
| 4    | `SP_DEC`    | `CALL`, `PUSH`: R3 = R3 - 1                               |
| 5    | `MEMORY`    | `dmem_re` or `dmem_we` is high for this clock             |
| 6    | `MEM_WAIT`  | `dmem_rdata` is valid, and `result` loads it              |
| 7    | `SP_INC`    | `RET`, `POP`: R3 = R3 + 1                                 |
| 8    | `WRITEBACK` | rd loads `result`                                         |
| 9    | `RETIRE`    | `retire` pulses, and `pc` moves on                        |
| 10   | `HALTED`    | Stays here until reset                                    |

`DECODE` loads nothing. `decode` from Tutorial 16 is combinational, so its outputs are
already right once `ir` has loaded. This clock is here for clarity: each decision has its
own state, and you can read the route off a waveform.

`RETIRE` is also a state of its own, so that when `retire` is high every effect is
already visible in the registers and memory. Only `pc` is left to move, so `retire_pc`
is simply `pc`, and `retire_instr` is `ir`. Tutorial 18 relies on this.

## Why the FSM has to wait

Both memories are synchronous, as in Tutorial 6: data appears one clock **after** the
address. In `FETCH` the address is on the wires, but `imem_data` still holds the word
from before. If `ir` loaded here, every instruction would run the one before it.

So the FSM spends a clock doing nothing but waiting. That is `WAIT`, and `MEM_WAIT` is
the same thing for data. A wait state is what any FSM needs when it talks to something
with latency, and the FSM is what makes it easy: one more state and no other change.
Writes need no wait, because `dmem_we` and the address go in together at the edge.

## How each class uses the datapath

All instructions start with `FETCH`, `WAIT`, `DECODE`. Then:

| Class                             | Route after `DECODE`                                    | Clocks |
| --------------------------------- | ------------------------------------------------------- | ------ |
| `NOP`, `HALT`, `JMP`, `JR`, `Bcc`, illegal | `RETIRE`                                       | 4      |
| `CMP`, `CMPI`                     | `EXECUTE`, `RETIRE`                                     | 5      |
| ALU, `LDI`, `ADDI`, `ANDI`        | `EXECUTE`, `WRITEBACK`, `RETIRE`                        | 6      |
| `ST`                              | `EXECUTE`, `MEMORY`, `RETIRE`                           | 6      |
| `CALL`, `PUSH`                    | `EXECUTE`, `SP_DEC`, `MEMORY`, `RETIRE`                 | 7      |
| `LD`                              | `EXECUTE`, `MEMORY`, `MEM_WAIT`, `WRITEBACK`, `RETIRE`  | 8      |
| `RET`                             | `EXECUTE`, `MEMORY`, `MEM_WAIT`, `SP_INC`, `RETIRE`     | 8      |
| `POP`                             | `EXECUTE`, `MEMORY`, `MEM_WAIT`, `SP_INC`, `WRITEBACK`, `RETIRE` | 9 |

The clocks are observed, not calculated: `make sim` times every instruction it runs and
fails if one differs from this table. `Bcc` takes 4 clocks whether or not it is taken.

- **Jumps and branches** only choose the PC. The `pc_sel_` outputs of `decode` steer one
  multiplexer in `RETIRE`, which is why these take the short route.
- **Calculations** take `a` from rd, and `b` from rs or imm. The result goes to `result`
  in `EXECUTE`, and to rd in `WRITEBACK`. `CMP` skips `WRITEBACK`, and that is the whole
  difference between it and `SUB`.
- **`LD` and `ST`** have their own adder for rs + imm, as the spec says, because the
  ALU's `a` is rd. `ST` copies rd to `result` in `EXECUTE`, and `dmem_wdata` is `result`.

`result` loads in every `EXECUTE`, even when nothing needs it. In a `RET`, the ALU's
output goes in and is then overwritten in `MEM_WAIT`. It costs nothing, and one less
condition is one less thing to get wrong.

## How the stack works in hardware

The stack needs no new memory, only an address that comes from R3. Two pieces do it.

The register file has two read ports, so port a is switched to R3 for stack
instructions, and `dmem_addr` uses it in place of rs + imm. Port b still reads rs, which
`PUSH` needs. This ignores the rd field, so junk there does no harm:

```verilog
.raddr_a(uses_stack ? SP : rd),
```

A small adder makes `sp_next`, which is R3 - 1 in `SP_DEC` and R3 + 1 in `SP_INC`. The
one write port takes it in those states, and takes `result` for rd in `WRITEBACK`.

The **order of the states** is the design. A push decrements first and then stores,
because the stack pointer points at the last item used. A pop loads first and then
increments. The spec's two special cases then need no special logic:

- `PUSH R3` stores the old R3, because `EXECUTE` copies it to `result` before `SP_DEC`.
- `POP R3` keeps the loaded value, because `WRITEBACK` comes after `SP_INC`, so the
  loaded value is written last.

[`programs/stack_r3.asm`](programs/stack_r3.asm) tests both.

## The programs

`make sim` assembles everything in `programs/` into `build/` first, using
[`tools/asm.py`](tools/asm.py), which is unchanged from Tutorial 16.

| Program               | What it shows                                         | Result checked       |
| --------------------- | ----------------------------------------------------- | -------------------- |
| `demo.asm`            | Tutorial 16's program, running for real               | 30 at 0x80           |
| `add_multi.asm`       | A 24-bit add, with `ADC` carrying between bytes       | 0x01010000 at 0x18   |
| `fibonacci.asm`       | A loop, ended by the carry flag                       | 14 numbers at 0x40   |
| `recursive_sum.asm`   | A subroutine that calls itself, seven calls deep      | 21 at 0x80, and the stack |
| `memcpy.asm`          | `LD` and `ST` with one pointer and an offset          | 8 bytes at 0x30      |
| `branches.asm`        | All 12 conditions both ways, signed and unsigned      | 0xAA at 0x80         |
| `stack_r3.asm`        | `PUSH R3` and `POP R3`                                | R0 to R3, and memory |

`add_multi.asm` is worth reading for what it cannot do. It is not a loop, because
stepping a pointer needs `ADDI`, which would destroy the carry that `ADC` needs next.

`branches.asm` uses the same compare to show that signed and unsigned disagree:
`0xFF` against 1 is `BLT` as signed numbers, and `BHS` as unsigned ones.

## Simulate

[`tb/tb_cpu.v`](tb/tb_cpu.v) runs each program, and checks the final registers, memory,
PC and instruction count against values worked out by hand. It loads a program with
`$readmemh`, so it needs no recompiling. Then it tests the four kinds of illegal word,
`HALT` with junk in its unused fields, and a reset at each of the first 120 clocks of a
run. rst is the only input a CPU has, and it is driven on falling edges.

```bash
make sim
```

Each program prints one line, and the table of clocks comes next. These are real
results, shortened:

```text
build/demo.hex: 51 instructions, 329 clocks
build/branches.hex: 61 instructions, 285 clocks
ALU: 900 seen, 6 to 6 clocks
POP: 72 seen, 9 to 9 clocks
PASS: 1513 instructions retired
```

So `demo` averages about 6.5 clocks per instruction, and `branches`, which is mostly
4-clock branches, about 4.7.

## One instruction, clock by clock

Use a fresh simulation for this step, because `make verilator` writes the same file and
has no `x`. Run `make sim`, then open `build/tb_cpu.vcd` as in Tutorial 1. Add `clk` from
`tb_cpu`, and `state`, `pc`, `imem_data`, `ir`, `rdata_a`, `result`, `dmem_addr`, `dmem_re`,
`dmem_we`, `dmem_rdata`, `dmem_wdata` and `retire` from `dut.u_cpu`.

This is the first `CALL add_double`, the word `A009` at address 04 of `demo.asm`. Each row
is the value just before the rising edge at that time:

| Edge (ns) | `state`     | `pc` | `imem_data` | `ir`   | `rdata_a` | `result` | What the edge does      |
| --------- | ----------- | ---- | ----------- | ------ | --------- | -------- | ----------------------- |
| 275       | 0 `FETCH`   | 04   | `2880`      | `2880` | `80`      | `80`     | Memory takes address 04 |
| 285       | 1 `WAIT`    | 04   | `A009`      | `2880` | `80`      | `80`     | `ir` loads `A009`       |
| 295       | 2 `DECODE`  | 04   | `A009`      | `A009` | `F0`      | `80`     | The route is chosen     |
| 305       | 3 `EXECUTE` | 04   | `A009`      | `A009` | `F0`      | `80`     | `result` loads PC + 1   |
| 315       | 4 `SP_DEC`  | 04   | `A009`      | `A009` | `F0`      | `05`     | R3 becomes `EF`         |
| 325       | 5 `MEMORY`  | 04   | `A009`      | `A009` | `EF`      | `05`     | 05 is stored at `EF`    |
| 335       | 9 `RETIRE`  | 04   | `A009`      | `A009` | `EF`      | `05`     | `pc` becomes 09         |

- In the first row `imem_data` still shows the last word, and `A009` arrives a clock
  later. This is the wait state, on a real trace.
- `rdata_a` is 80, which is R2, while `ir` holds the `LDI R2` before this. As soon as `ir`
  holds a stack instruction, the same wires show R3.
- `dmem_we` is high only for the clock before 325 ns, with `dmem_addr` at `EF` and
  `dmem_wdata` at 05. `retire` is high only for the clock before 335 ns.
- `dmem_rdata` is `x`, as no read has happened yet, and nothing looks at it.
- From 335 ns `state` is 0 again, `pc` is 09, and the next instruction starts.

For a read, follow the first `RET` (`B000`), which retires at 755 ns. After `EXECUTE`,
`state` goes 5, 6, 7, 9. `dmem_re` is high in state 5, `dmem_rdata` becomes 05 a clock
later, and `result` loads it. `result` shows `F4` in state 5, the unused ALU output.

## Lint and Verilator

```bash
make lint
make verilator
```

Any warning starts with `%Warning`. The lines that start with `- V e r i l a t i o n`
are a normal report. Lint runs twice, on `cpu` and on `cpu_top`.

`decode` has outputs that this CPU does not need, since `pc_sel_` already covers them.
Their wires are named `unused_`, which Verilator accepts as a statement of intent.

`make verilator` runs the same testbench and prints the same lines.

## Test in Python

[`tb/test_cpu.py`](tb/test_cpu.py) writes random programs, which is the simplest way to
meet combinations nobody thought of.

```bash
make cocotb
```

Look for `TESTS=1 PASS=1 FAIL=0`, and this line:

```text
300 programs, 55483 instructions, 55 classes, rarest was BVC_not_taken with 5
```

The seed is fixed at 18, as in Tutorials 18 and 20, so that a run can be repeated. Seeds 1
to 20 all pass, and on them the rarest class ran between 3 and 12 times, so a class can come
close to never running. To try another seed, use `make cocotb SEED=7`.

A random word is usually an illegal instruction or a wild jump, so the generator writes
random **source text** by rules that keep the program safe. Branches and jumps only go
forward, so it must end. `CALL` goes to subroutines that balance their stack. R3 is
never a target, and data addresses are masked to stay below the stack. Then
`tools/asm.py` assembles it, and junk goes into the fields each instruction ignores.

A small Python model runs the same words. After `HALT`, the test compares all registers,
flags, the PC, all 256 bytes of memory and the number of retires. It counts 55 classes,
which include each branch both taken and not taken, and `PUSH R3` and `POP R3`, and it
fails if any class never ran.

This only compares the end of each program. A bug that cancels itself out before `HALT`
would pass. Tutorial 18 compares after every instruction.

## Prove it with formal verification

```bash
make formal
```

[`cpu.sby`](cpu.sby) has two tasks. Look for `successful proof by k-induction` and then
`DONE (PASS, rc=0)` for each of them. It takes seconds.

The proof in `rtl/cpu.v` is about structure, not answers. It says nothing about whether
`ADD` adds. It proves that:

- `state` is always one of the 11 named states.
- Memory is written and read only in `MEMORY`, and only by the right instructions.
- Each fetch gets exactly one retire. `f_pending` goes high when `ir` loads, and a retire
  needs it high, while a fetch needs it low. No instruction takes more than 9 clocks.
- `halted` stays high until reset, and nothing changes while it is high.
- `pc` changes only at `RETIRE` or reset, and `ir` only at `WAIT` or reset.
- Reset goes to `FETCH`, and never touches memory or counts as a retire.

There is no assumption on `imem_data` or `dmem_rdata`. They are free inputs, so the solver
may hand the CPU a different random word on every clock. That makes these facts stronger
than they look: they hold for every program, and even for broken memories.

`depth 12` is there because `f_age`, the clock count behind the 9-clock limit, has no
helper tying it to `state`. Induction needs a window long enough to pass through a
`FETCH`, which clears it. At depth 8 the proof ends `UNKNOWN`, and at 10 it passes.

The `cover` task uses the same free inputs to reach a retire of every class, plus
`halted` with and without `illegal`. So the assertions are not empty.

The sub-modules are read without their own `FORMAL` blocks, because Tutorials 11, 12 and
16 proved those already.

## See the logic

```bash
make schematic
```

Click `build/cpu.png` in the Explorer. The whole CPU flattened to gates would be
unreadable, so this is only the top level of `cpu`, with `decode`, `regfile` and
`alu_flags` as boxes. It is still very wide, so zoom in and look for landmarks:

![Schematic of the CPU](images/schematic.png)

- `u_decode` is at the left, and `u_flags` to its left feeds it the flags.
- `u_alu` is along the top, and `u_regfile` near the right.
- In the middle, one `$dff` is the `state` register. Beside it, a column of `$eq` blocks
  compares `state` with each code. These are the FSM's control signals.
- `u_ir`, `u_pc` and `u_result` are the other boxes. Each has `en` driven by one of those
  control signals, and that is the whole connection between control and datapath.
- The chains of `$mux` blocks are `next_state`, `exec_value` and `pc_next`.

## Map it to real FPGAs

```bash
make synth
```

| Family     | Flip-flops           | Total cells |
| ---------- | -------------------- | ----------- |
| Xilinx     | 79 `FDRE`            | 315         |
| Gowin      | 68 `DFFRE`, 11 `DFF` | 974         |
| Cyclone V  | 79 `MISTRAL_FF`      | 316         |

The datapath is 68 flip-flops: 32 in the registers, 16 in `ir`, 8 each in `pc` and
`result`, and 4 flags. The other 11 are the FSM. Yosys recognised it and recoded `state`
from 4 bits to one-hot, with one flip-flop for each of the 11 states, as in Tutorial 5.
Gowin's total includes 303 `MUX2_LUT` cells and 258 `LUT1`. These are Yosys counts, so
vendor tools can give different results, and they say nothing about timing.

`make pnr` from [Tutorial 15](../15-pipelining/README.md) works here too, on `cpu_top`,
where the memories became two block RAMs, with `demo.hex` as the program. It places the
design five times, and these are the five results:

```bash
make pnr
```

| Lowest    | Middle    | Highest   |
| --------- | --------- | --------- |
| 52.31 MHz | 55.01 MHz | 57.91 MHz |

This is an open-source estimate for a GW1N-9C, not a vendor result. In all five the
worst path starts at `ir` and ends at `result` or the `z` flag: the logic that makes
sense of an instruction and then does the sum, all in one clock.

Most of this CPU's clocks are spent moving between states, not doing sums. Tutorial 20
goes after that by overlapping instructions. This version is slower, but it has no
hazards to think about.

## Try it yourself

Change `rtl/cpu.v`, then run `make sim`, `make cocotb` and `make formal`. Undo each change
before trying the next.

1. In `assign retire`, add `|| state == S_WRITEBACK` inside the brackets.
2. In `assign dmem_we`, replace `(state == S_MEMORY)` with
   `(state == S_MEMORY || state == S_SP_DEC)`.
3. Add `|| (state == S_DECODE)` to `pc_load`, so the PC moves early.
4. Replace `S_HALTED:    next_state = S_HALTED;` with `next_state = S_FETCH;`.

Each mistake is caught by all three. The rest are more interesting.

**A proof of structure is not a proof of correctness.** Try each of these. `make sim` and
`make cocotb` fail, and `make formal` passes every time, since it never asks what any
value should be. That is what Tutorial 18 is for.

- Remove `&& flags_we` from `flags_load`, so `LDI` and `LD` change the flags.
- In `exec_value`, replace `pc_plus_1` with `pc`, so `RET` comes back to the `CALL`.
- In `assign dmem_addr`, replace `rdata_b + imm` with `rdata_a + imm`.

**Removing a wait state.** In `result_load`, and in the `.d(` line of `u_result`, replace
`S_MEM_WAIT` with `S_MEMORY`. Now `result` loads a clock too early and every read gets
whatever the read before it returned. `demo` never halts, and `memcpy` shows the pattern
exactly: `FAIL mem[31]=07 expected=26`, because 07 is the byte before. The proof still
passes, since no property mentions data.

**A bug only one program sees.** Replace `.carry_in(flag_c)` with `.carry_in(1'b0)`. Only
`add_multi` fails, with `FAIL mem[19]=ff expected=00`, since no other program uses
`ADC`. Now undo that, and replace `assign dmem_wdata = result;` with
`assign dmem_wdata = push ? rdata_b : result;`. It looks like a harmless shortcut, and
it is right for every `PUSH` except `PUSH R3`, so only `stack_r3` fails.

**A bug only Python sees.** Add `|| ir[15:8] == 8'h01` to `stops`, so a `NOP` with junk in
rs halts. `make sim` passes, since assembled programs have zeros there. `make cocotb`
fails, because of the junk it adds on purpose.

**A bug only reset sees.** Remove `!rst &&` from `dmem_we`. `make sim` fails with
`memory write or retire during reset`, and `make formal` fails. `make cocotb` passes,
because it only resets between programs.

**A faster CPU that fails the tests.** `FETCH` wastes a clock: `RETIRE` knows the next
address already. Replace `S_RETIRE:    next_state = stops ? S_HALTED : S_FETCH;` with
`... : S_WAIT;`, and `assign imem_addr = pc;` with
`assign imem_addr = pc_load ? pc_next : pc;`. `demo` drops from 329 clocks to 279 with
every result right, and `make cocotb` passes. But `make sim` fails, only on its table of
clocks, and `make formal` ends `DONE (UNKNOWN, rc=4)`, because `f_age` counted on
`FETCH`. The tests describe this design, not just correct behaviour, so a good change
can break them. Read why a test failed before deciding who is wrong.

**A bug in the assembler.** In `tools/asm.py`, replace `"BLO": 10, "BHS": 11` with `"BLO":
11, "BHS": 10`. `make sim` fails: `branches` reaches `fail`, with `mem[80]=ee`. `make
cocotb` passes, because its model runs the same wrong words the CPU does, which is
Tutorial 16's warning about two sides that agree with each other.
