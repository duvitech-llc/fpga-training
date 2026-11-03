RTL := rtl/cpu.v rtl/decode.v rtl/alu_flags.v rtl/regfile.v rtl/enreg.v
TOP_RTL := rtl/cpu_top.v $(RTL)
TB  := tb/tb_cpu.v
TOP := cpu
SEED ?= 18
PROGRAMS := $(wildcard programs/*.asm)
HEX := $(patsubst programs/%.asm,build/%.hex,$(PROGRAMS))
TRACES := $(patsubst programs/%.asm,build/%.trace,$(PROGRAMS))

.PHONY: all asm sim cpi lint verilator cocotb formal synth schematic pnr clean

all: asm sim cpi lint verilator cocotb formal synth schematic pnr

build:
	mkdir -p build

build/%.hex: programs/%.asm tools/asm.py | build
	python3 tools/asm.py $< $@

# What the reference model did, one line per instruction.
build/%.trace: build/%.hex tools/iss.py
	python3 tools/iss.py $< --trace $@

# 256 zero bytes, which the testbench loads to empty data memory between programs.
build/empty.hex: | build
	python3 -c "print('00\n' * 256, end='')" > $@

asm: $(HEX) $(TRACES) build/empty.hex

sim: asm
	iverilog -g2012 -o build/tb_cpu.vvp $(TB) $(TOP_RTL)
	vvp build/tb_cpu.vvp

# Every program at every STEP, under Icarus and then Verilator. STEP is the only thing
# that changes. A STEP that fails does not stop the others, but it does fail the target.
cpi: asm
	@failed=0; \
	for step in 0 1 2 3 4; do \
		iverilog -g2012 -Ptb_cpi.STEP=$$step -o build/tb_cpi.vvp tb/tb_cpi.v $(TOP_RTL) || exit 1; \
		vvp build/tb_cpi.vvp || failed=1; \
	done; \
	for step in 0 1 2 3 4; do \
		verilator --binary --timing -GSTEP=$$step --Mdir build/obj_cpi_$$step \
			--top-module tb_cpi tb/tb_cpi.v $(TOP_RTL) > build/verilator_cpi_$$step.log || exit 1; \
		build/obj_cpi_$$step/Vtb_cpi || failed=1; \
	done; \
	exit $$failed

# The CPU alone at each STEP, then with its memories.
lint:
	@for step in 0 1 2 3 4; do \
		verilator --lint-only -Wall -GSTEP=$$step --top-module $(TOP) $(RTL) || exit 1; \
	done
	verilator --lint-only -Wall --top-module cpu_top $(TOP_RTL)

verilator: asm
	verilator --binary --timing --trace --Mdir build/obj_dir \
		--top-module tb_cpu $(TB) $(TOP_RTL)
	build/obj_dir/Vtb_cpu

cocotb: | build
	$(MAKE) -C tb SEED=$(SEED)

# The structural proof and its cover, then one proof for each class of instruction.
formal: | build
	sby -f --prefix build/formal cpu.sby
	sby -f --prefix build/insn insn.sby
	@echo "$$(grep -l 'DONE (PASS' build/formal_*/logfile.txt build/insn_*/logfile.txt | wc -l) tasks passed"

# The flags leave out I/O and clock buffers so the counts show only the logic.
synth: | build
	yosys -q -p "read_verilog $(RTL); synth_xilinx -family xc7 -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-xilinx.txt stat"
	yosys -q -p "read_verilog $(RTL); synth_gowin -top $(TOP) -noiopads; tee -o build/stat-gowin.txt stat"
	yosys -q -p "read_verilog $(RTL); synth_intel_alm -family cyclonev -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-cyclonev.txt stat"
	@for family in xilinx gowin cyclonev; do \
		echo "--- $$family"; sed -n '/cells$$/,$$p' build/stat-$$family.txt; \
	done

# The whole CPU is too wide to read, so this is what feeds ex_a, the ALU's a input.
schematic: | build
	yosys -q -p "read_verilog $(RTL); prep -top $(TOP); show -format png -prefix build/forward $(TOP)/w:ex_a %ci5 $(TOP)/w:forward_a_mem %ci5 %u"

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
