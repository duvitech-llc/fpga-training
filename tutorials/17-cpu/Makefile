RTL := rtl/cpu.v rtl/decode.v rtl/alu_flags.v rtl/regfile.v rtl/enreg.v
TOP_RTL := rtl/cpu_top.v $(RTL)
TB  := tb/tb_cpu.v
TOP := cpu
SEED ?= 18
PROGRAMS := $(wildcard programs/*.asm)
HEX := $(patsubst programs/%.asm,build/%.hex,$(PROGRAMS))

.PHONY: all asm sim lint verilator cocotb formal synth schematic pnr clean

all: asm sim lint verilator cocotb formal synth schematic pnr

build:
	mkdir -p build

build/%.hex: programs/%.asm tools/asm.py | build
	python3 tools/asm.py $< $@

# 256 zero bytes, which the testbench loads to empty data memory between programs.
build/empty.hex: | build
	python3 -c "print('00\n' * 256, end='')" > $@

asm: $(HEX) build/empty.hex

sim: asm
	iverilog -g2012 -o build/tb_cpu.vvp $(TB) $(TOP_RTL)
	vvp build/tb_cpu.vvp

# The CPU alone, then with its memories.
lint:
	verilator --lint-only -Wall --top-module $(TOP) $(RTL)
	verilator --lint-only -Wall --top-module cpu_top $(TOP_RTL)

verilator: asm
	verilator --binary --timing --trace --Mdir build/obj_dir \
		--top-module tb_cpu $(TB) $(TOP_RTL)
	build/obj_dir/Vtb_cpu

cocotb: | build
	$(MAKE) -C tb SEED=$(SEED)

# Two tasks: the proof, and cover.
formal: | build
	sby -f --prefix build/formal cpu.sby

# The flags leave out I/O and clock buffers so the counts show only the logic.
synth: | build
	yosys -q -p "read_verilog $(RTL); synth_xilinx -family xc7 -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-xilinx.txt stat"
	yosys -q -p "read_verilog $(RTL); synth_gowin -top $(TOP) -noiopads; tee -o build/stat-gowin.txt stat"
	yosys -q -p "read_verilog $(RTL); synth_intel_alm -family cyclonev -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-cyclonev.txt stat"
	@for family in xilinx gowin cyclonev; do \
		echo "--- $$family"; sed -n '/cells$$/,$$p' build/stat-$$family.txt; \
	done

# Only the top level of cpu, with u_decode, u_regfile and u_alu left as boxes.
schematic: | build
	yosys -q -p "read_verilog $(RTL); prep -top $(TOP); show -format png -prefix build/$(TOP) $(TOP)"

# An open-source estimate for a Gowin GW1N-9C. This is not a vendor result.
pnr: build/demo.hex | build
	yosys -q -p "read_verilog $(TOP_RTL); chparam -set PROGRAM \"build/demo.hex\" cpu_top; synth_gowin -top cpu_top -json build/top.json; tee -o build/stat-top.txt stat"
	@for seed in 1 2 3 4 5; do \
		nextpnr-himbaechel --device GW1NR-LV9QN88PC6/I5 --vopt family=GW1N-9C \
			--vopt cst=cpu_top.cst --json build/top.json --freq 25 \
			--seed $$seed --threads 1 > build/pnr-$$seed.log 2>&1 || exit 1; \
		echo "seed=$$seed: $$(grep 'Max frequency' build/pnr-$$seed.log | tail -1 | sed 's/.*: *//')"; \
	done

clean:
	rm -rf build tb/__pycache__ tools/__pycache__
