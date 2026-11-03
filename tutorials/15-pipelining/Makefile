RTL := rtl/pipe_adder.v
TB  := tb/tb_pipe_adder.v
TOP := pipe_adder
WIDTH ?= 32
STAGES ?= 2
SIMPLE ?= 0
PARAMS := -set WIDTH $(WIDTH) -set STAGES $(STAGES)

.PHONY: all sim lint verilator cocotb formal synth schematic depth pnr clean

all: sim lint verilator cocotb formal synth schematic depth pnr

build:
	mkdir -p build

sim: | build
	iverilog -g2012 -Ptb_pipe_adder.WIDTH=$(WIDTH) -Ptb_pipe_adder.STAGES=$(STAGES) \
		-Ptb_pipe_adder.SIMPLE=$(SIMPLE) -o build/tb_pipe_adder.vvp $(TB) $(RTL)
	vvp build/tb_pipe_adder.vvp

lint:
	verilator --lint-only -Wall -GWIDTH=$(WIDTH) -GSTAGES=$(STAGES) --top-module $(TOP) $(RTL)
	verilator --lint-only -Wall -GWIDTH=$(WIDTH) -GSTAGES=$(STAGES) --top-module $(TOP)_top \
		rtl/$(TOP)_top.v $(RTL)

verilator: | build
	verilator --binary --timing --trace -GWIDTH=$(WIDTH) -GSTAGES=$(STAGES) -GSIMPLE=$(SIMPLE) \
		--Mdir build/obj_dir --top-module tb_pipe_adder $(TB) $(RTL)
	build/obj_dir/Vtb_pipe_adder

cocotb: | build
	$(MAKE) -C tb WIDTH=$(WIDTH) STAGES=$(STAGES)

# Proves WIDTH=32 at 1, 2, 3 and 4 stages, whatever is set here.
formal: | build
	sby -f --prefix build/formal pipe_adder.sby

# The flags leave out I/O and clock buffers so the counts show only the logic.
synth: | build
	yosys -q -p "read_verilog $(RTL); chparam $(PARAMS) $(TOP); synth_xilinx -family xc7 -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-xilinx.txt stat"
	yosys -q -p "read_verilog $(RTL); chparam $(PARAMS) $(TOP); synth_gowin -top $(TOP) -noiopads; tee -o build/stat-gowin.txt stat"
	yosys -q -p "read_verilog $(RTL); chparam $(PARAMS) $(TOP); synth_intel_alm -family cyclonev -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-cyclonev.txt stat"
	@for family in xilinx gowin cyclonev; do \
		echo "--- $$family"; sed -n '/cells$$/,$$p' build/stat-$$family.txt; \
	done

# Drawn at 8 bits, because 32 would not be readable.
schematic: | build
	yosys -q -p "read_verilog $(RTL); chparam -set WIDTH 8 -set STAGES 2 $(TOP); prep -top $(TOP); show -format png -prefix build/$(TOP)"

# The longest path with no flip-flop in it, in simple gates. Not a clock speed.
depth: | build
	@for s in 1 2 4; do \
		yosys -q -p "read_verilog $(RTL); chparam -set WIDTH $(WIDTH) -set STAGES $$s $(TOP); synth -flatten -top $(TOP); abc -g AND; opt_clean; tee -o build/ltp-$$s.txt ltp -noff"; \
		echo "STAGES=$$s: $$(grep -o 'length=[0-9]*' build/ltp-$$s.txt) logic levels"; \
	done

# An open-source estimate for a Gowin GW1N-9C. This is not a vendor result.
pnr: | build
	@for s in 1 2 4; do \
		yosys -q -p "read_verilog $(RTL) rtl/$(TOP)_top.v; chparam -set WIDTH $(WIDTH) -set STAGES $$s $(TOP)_top; synth_gowin -top $(TOP)_top -json build/top-$$s.json"; \
		for seed in 1 2 3 4 5; do \
			nextpnr-himbaechel --device GW1NR-LV9QN88PC6/I5 --vopt family=GW1N-9C \
				--vopt cst=$(TOP).cst --json build/top-$$s.json --freq 100 \
				--seed $$seed --threads 1 > build/pnr-$$s-$$seed.log 2>&1 || exit 1; \
			echo "STAGES=$$s seed=$$seed: $$(grep 'Max frequency' build/pnr-$$s-$$seed.log | tail -1 | sed 's/.*: *//')"; \
		done; \
	done

clean:
	rm -rf build tb/__pycache__
