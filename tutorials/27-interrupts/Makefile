CORE := rtl/rv32i.v rtl/rv_decode.v rtl/rv_alu.v rtl/rv_regs.v rtl/enreg.v rtl/rv_csr.v
UART := rtl/uart.v rtl/uart_tx.v rtl/uart_rx.v
RTL  := rtl/soc.v $(CORE) rtl/rv_wb_bridge.v rtl/wb_interconnect.v rtl/wb_ram.v \
	rtl/wb_uart.v $(UART) rtl/wb_gpio.v rtl/wb_counters.v rtl/wb_timer.v \
	rtl/wb_axil_bridge.v rtl/axil_regs.v
TOP  := soc
SEED ?= 27
CLKS_PER_BIT ?= 16

ASM_PROGRAMS := $(wildcard programs/*.asm)
C_PROGRAMS   := $(wildcard programs/*.c)
HEX := $(patsubst programs/%.asm,build/%.hex,$(ASM_PROGRAMS)) \
	$(patsubst programs/%.c,build/%.hex,$(C_PROGRAMS))
EXIT := $(patsubst programs/%.c,build/%.exit,$(C_PROGRAMS))
DIS  := $(patsubst programs/%.c,build/%.dis,$(C_PROGRAMS))
# Keep the ELF files and binaries, which make would otherwise delete as intermediates.
.SECONDARY: $(patsubst programs/%.c,build/%.elf,$(C_PROGRAMS)) \
	$(patsubst programs/%.c,build/%.bin,$(C_PROGRAMS))

# The C compiler, from the xPack RISC-V GCC in the image.
#   -march=rv32i_zicsr  the base integer set and the CSR instructions: nothing else
#   -mabi=ilp32         int, long and pointers are 32 bits; no floating-point registers
#   -ffreestanding      no hosted C library: main is not special, no built-in printf
#   -nostdlib           link no libc and no startup files: sw/crt0.S is ours
#   -lgcc               but do link libgcc, for multiply and divide, which RV32I lacks
#   -T sw/link.ld       our linker script: where everything goes in the RAM
# The other flags: -O2 optimizes, -Wall -Wextra -Werror make every warning an
# error, and --gc-sections drops functions nothing calls. Code and data share one
# RAM, so the program is one segment that is readable, writable and executable,
# which the linker would warn about.
CC      := riscv-none-elf-gcc
OBJCOPY := riscv-none-elf-objcopy
OBJDUMP := riscv-none-elf-objdump
NM      := riscv-none-elf-nm
CFLAGS  := -march=rv32i_zicsr -mabi=ilp32 -O2 -ffreestanding -nostdlib -Wall -Wextra -Werror \
	-Isw
LDFLAGS := -T sw/link.ld -ffunction-sections -fdata-sections -Wl,--gc-sections \
	-Wl,--no-warn-rwx-segments
SW      := sw/crt0.S sw/lib.c

.PHONY: all asm sim lint verilator cocotb formal synth schematic clean

all: asm sim lint verilator cocotb formal synth schematic

build:
	mkdir -p build

# Assembly: Tutorial 21's assembler, then the words padded to the full 64 KiB, so
# that $readmemh fills the whole RAM and has nothing to warn about.
build/%.hex: programs/%.asm tools/asm.py tools/pad_hex.py | build
	python3 tools/asm.py $< $@.raw
	python3 tools/pad_hex.py $@.raw $@ 16384

# C: compile and link with crt0 and lib.c, then the RAM image as raw bytes, then
# words for $readmemh. The .exit file holds _exit's address, where crt0's ebreak is,
# for the testbench. The .dis file is the disassembly, to read.
build/%.elf: programs/%.c $(SW) sw/soc.h sw/link.ld | build
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SW) $< -lgcc

build/%.bin: build/%.elf
	$(OBJCOPY) -O binary $< $@

build/%.hex: build/%.bin tools/bin2hex.py
	python3 tools/bin2hex.py $< $@ 16384

build/%.exit: build/%.elf
	$(NM) $< | awk '$$3 == "_exit" { print $$1 }' > $@

build/%.dis: build/%.elf
	$(OBJDUMP) -d $< > $@

asm: $(HEX) $(EXIT) $(DIS)
	python3 tools/test_asm.py

sim: asm
	iverilog -g2012 -Irtl -Ptb_soc.CLKS_PER_BIT=$(CLKS_PER_BIT) -o build/tb_soc.vvp tb/tb_soc.v $(RTL)
	vvp -n build/tb_soc.vvp

# The whole system, the core alone, then each new or changed module on its own.
lint:
	verilator --lint-only -Wall -Irtl -GCLKS_PER_BIT=$(CLKS_PER_BIT) --top-module $(TOP) $(RTL)
	verilator --lint-only -Wall --top-module rv32i $(CORE)
	verilator --lint-only -Wall --top-module rv_csr rtl/rv_csr.v
	verilator --lint-only -Wall --top-module wb_timer rtl/wb_timer.v
	verilator --lint-only -Wall --top-module wb_uart rtl/wb_uart.v $(UART)

verilator: asm
	verilator --binary --timing --trace -Irtl -GCLKS_PER_BIT=$(CLKS_PER_BIT) --Mdir build/obj_soc \
		--top-module tb_soc tb/tb_soc.v $(RTL) > build/verilator_soc.log
	build/obj_soc/Vtb_soc

cocotb: asm
	$(MAKE) -C tb SEED=$(SEED) CLKS_PER_BIT=$(CLKS_PER_BIT)

# The core, one class of instruction at a time, with traps and interrupts; then
# the interconnect with this system's map.
formal: | build
	sby -f --prefix build/formal insn.sby
	sby -f --prefix build/formal bus.sby
	@echo "$$(grep -l 'DONE (PASS' build/formal_*/logfile.txt | wc -l) tasks passed"

# The flags leave out I/O and clock buffers so the counts show only the logic.
# The core alone first, to compare with Tutorial 21, then the whole system with
# hello.c in its RAM.
synth: build/hello.hex | build
	yosys -q -p "read_verilog $(CORE); synth_xilinx -family xc7 -top rv32i -noiopad -noclkbuf; tee -o build/stat-xilinx-rv32i.txt stat"
	@echo "--- rv32i xilinx"; sed -n '/cells$$/,$$p' build/stat-xilinx-rv32i.txt
	yosys -q -p "read_verilog -Irtl $(RTL); chparam -set INIT \"build/hello.hex\" -set CLKS_PER_BIT $(CLKS_PER_BIT) $(TOP); synth_xilinx -family xc7 -top $(TOP) -noiopad -noclkbuf -flatten; tee -o build/stat-xilinx.txt stat"
	yosys -q -p "read_verilog -Irtl $(RTL); chparam -set INIT \"build/hello.hex\" -set CLKS_PER_BIT $(CLKS_PER_BIT) $(TOP); synth_gowin -top $(TOP) -noiopads; tee -o build/stat-gowin.txt stat"
	yosys -q -p "read_verilog -Irtl $(RTL); chparam -set INIT \"build/hello.hex\" -set CLKS_PER_BIT $(CLKS_PER_BIT) $(TOP); synth_intel_alm -family cyclonev -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-cyclonev.txt stat"
	@for family in xilinx gowin cyclonev; do \
		echo "--- $(TOP) $$family"; sed -n '/cells$$/,$$p' build/stat-$$family.txt; \
	done

# The timer. The core and the system would be unreadable.
schematic: | build
	yosys -q -p "read_verilog rtl/wb_timer.v; prep -top wb_timer; show -format png -prefix build/wb_timer wb_timer"

clean:
	rm -rf build tb/__pycache__ tools/__pycache__
