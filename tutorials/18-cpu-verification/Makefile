RTL := rtl/cpu.v rtl/decode.v rtl/alu_flags.v rtl/regfile.v rtl/enreg.v
TOP_RTL := rtl/cpu_top.v $(RTL)
TB  := tb/tb_trace.v
TOP := cpu
SEED ?= 18
PROGRAMS := $(wildcard programs/*.asm)
HEX := $(patsubst programs/%.asm,build/%.hex,$(PROGRAMS))
TRACES := $(patsubst programs/%.asm,build/%.trace,$(PROGRAMS))

.PHONY: all asm sim lint verilator cocotb formal synth schematic clean

all: asm sim lint verilator cocotb formal synth schematic

build:
	mkdir -p build

build/%.hex: programs/%.asm tools/asm.py | build
	python3 tools/asm.py $< $@

# What the reference model did, one line per instruction, for tb_trace.v.
build/%.trace: build/%.hex tools/iss.py
	python3 tools/iss.py $< --trace $@

# 256 zero bytes, which the testbench loads to empty data memory between programs.
build/empty.hex: | build
	python3 -c "print('00\n' * 256, end='')" > $@

asm: $(HEX) $(TRACES) build/empty.hex

sim: asm
	iverilog -g2012 -o build/tb_trace.vvp $(TB) $(TOP_RTL)
	vvp build/tb_trace.vvp

# The CPU alone, then with its memories.
lint:
	verilator --lint-only -Wall --top-module $(TOP) $(RTL)
	verilator --lint-only -Wall --top-module cpu_top $(TOP_RTL)

verilator: asm
	verilator --binary --timing --trace --Mdir build/obj_dir \
		--top-module tb_trace $(TB) $(TOP_RTL)
	build/obj_dir/Vtb_trace

cocotb: | build
	$(MAKE) -C tb SEED=$(SEED)

# One proof for each class of instruction, plus fetch, structure and cover.
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

# The ALU alone, since that is where this lesson's hardest bug lives.
schematic: | build
	yosys -q -p "read_verilog rtl/alu_flags.v; prep -top alu_flags; show -format png -prefix build/alu_flags alu_flags"

clean:
	rm -rf build tb/__pycache__ tools/__pycache__
