RTL := rtl/rv32i.v rtl/rv_decode.v rtl/rv_alu.v rtl/rv_regs.v rtl/enreg.v
TB  := tb/tb_trace.v
TOP := rv32i
SEED ?= 21
PROGRAMS := $(wildcard programs/*.asm)
HEX := $(patsubst programs/%.asm,build/%.hex,$(PROGRAMS))
TRACES := $(patsubst programs/%.asm,build/%.trace,$(PROGRAMS))

.PHONY: all asm sim lint verilator cocotb formal synth schematic archtest clean

all: asm sim lint verilator cocotb formal synth schematic

build:
	mkdir -p build

build/%.hex: programs/%.asm tools/asm.py | build
	python3 tools/asm.py $< $@

# What the reference model did, one line per instruction, for tb_trace.v.
build/%.trace: build/%.hex tools/iss.py
	python3 tools/iss.py $< --trace $@

asm: $(HEX) $(TRACES) | build
	python3 tools/test_asm.py

sim: asm
	iverilog -g2012 -o build/tb_trace.vvp $(TB) $(RTL)
	vvp build/tb_trace.vvp

lint:
	verilator --lint-only -Wall --top-module $(TOP) $(RTL)

verilator: asm
	verilator --binary --timing --trace --Mdir build/obj_dir \
		--top-module tb_trace $(TB) $(RTL)
	build/obj_dir/Vtb_trace

cocotb: | build
	$(MAKE) -C tb SEED=$(SEED)

# One proof for each class of instruction, plus traps, the memory interface and cover.
formal: | build
	sby -f --prefix build/formal insn.sby
	@echo "$$(grep -l 'DONE (PASS' build/formal_*/logfile.txt | wc -l) tasks passed"

# The flags leave out I/O and clock buffers so the counts show only the logic.
synth: | build
	yosys -q -p "read_verilog $(RTL); synth_xilinx -family xc7 -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-xilinx.txt stat"
	yosys -q -p "read_verilog $(RTL); synth_gowin -top $(TOP) -noiopads; tee -o build/stat-gowin.txt stat"
	yosys -q -p "read_verilog $(RTL); synth_intel_alm -family cyclonev -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-cyclonev.txt stat"
	@for family in xilinx gowin cyclonev; do \
		echo "--- $$family"; sed -n '/cells$$/,$$p' build/stat-$$family.txt; \
	done

# The decoder alone. The whole core is too wide to read.
schematic: | build
	yosys -q -p "read_verilog rtl/rv_decode.v; prep -top rv_decode; show -format png -prefix build/rv_decode rv_decode"

# The official RISC-V architecture tests. Not part of all, because it downloads the
# suite. Only the test sources and the reference signatures are used: the suite's
# own scripts and Makefiles are never run.
ARCH_TAG    := 2.7.4
ARCH_COMMIT := 96e3589a867955e94c95ba098822da54d3ae39c0
ARCH_URL    := https://github.com/riscv-non-isa/riscv-arch-test.git
ARCH_DIR    := build/riscv-arch-test
ARCH_SUITE  := $(ARCH_DIR)/riscv-test-suite/rv32i_m
ARCH_OUT    := build/archtest
ARCH_CC     := riscv-none-elf-gcc -march=rv32i -mabi=ilp32 -static -nostdlib -nostartfiles \
               -Wl,--no-warn-rwx-segments -DXLEN=32 -Itb/arch \
               -I$(ARCH_DIR)/riscv-test-suite/env -T tb/arch/link.ld

$(ARCH_DIR): | build
	rm -rf $@.tmp
	git -c advice.detachedHead=false clone -q --depth 1 --branch $(ARCH_TAG) $(ARCH_URL) $@.tmp
	test "$$(git -C $@.tmp rev-parse HEAD)" = $(ARCH_COMMIT) \
		|| { echo "tag $(ARCH_TAG) is not commit $(ARCH_COMMIT)"; rm -rf $@.tmp; exit 1; }
	mv $@.tmp $@

# For each test: the program as one word per line from address 0, the reference, and
# a line in list.txt with the signature's first and last address, from nm.
archtest: $(ARCH_DIR)
	rm -rf $(ARCH_OUT)
	mkdir -p $(ARCH_OUT)
	@for src in $(ARCH_SUITE)/I/src/*.S; do \
		t=$$(basename $$src .S); \
		$(ARCH_CC) $$src -o $(ARCH_OUT)/$$t.elf || exit 1; \
		riscv-none-elf-objcopy -O binary $(ARCH_OUT)/$$t.elf $(ARCH_OUT)/$$t.bin || exit 1; \
		od -An -v -tx4 -w4 $(ARCH_OUT)/$$t.bin | tr -d ' ' > $(ARCH_OUT)/$$t.hex; \
		cp $(ARCH_SUITE)/I/references/$$t.reference_output $(ARCH_OUT)/$$t.ref || exit 1; \
		riscv-none-elf-nm $(ARCH_OUT)/$$t.elf > $(ARCH_OUT)/$$t.nm; \
		grep -q '^00000000 T rvtest_entry_point$$' $(ARCH_OUT)/$$t.nm \
			|| { echo "$$t: the entry point is not at address 0"; exit 1; }; \
		b=$$(awk '$$3 == "begin_signature" { print $$1 }' $(ARCH_OUT)/$$t.nm); \
		e=$$(awk '$$3 == "end_signature" { print $$1 }' $(ARCH_OUT)/$$t.nm); \
		[ -n "$$b" ] && [ -n "$$e" ] || { echo "$$t: no signature symbols"; exit 1; }; \
		echo "$$t $$b $$e" >> $(ARCH_OUT)/list.txt; \
	done
	@for src in $(ARCH_SUITE)/privilege/src/*.S; do \
		echo "$$(basename $$src .S): needs mtvec and a trap handler, so CSRs (Tutorial 27)"; \
	done >> $(ARCH_OUT)/skipped.txt
	@for src in $(ARCH_SUITE)/Zifencei/src/*.S; do \
		echo "$$(basename $$src .S): fence.i is Zifencei, not RV32I, and illegal on this core"; \
	done >> $(ARCH_OUT)/skipped.txt
	iverilog -g2012 -o $(ARCH_OUT)/tb_arch.vvp tb/tb_arch.v $(RTL)
	vvp -n $(ARCH_OUT)/tb_arch.vvp
	verilator --binary --timing --Mdir $(ARCH_OUT)/obj_dir --top-module tb_arch tb/tb_arch.v $(RTL)
	$(ARCH_OUT)/obj_dir/Vtb_arch

clean:
	rm -rf build tb/__pycache__ tools/__pycache__
