RTL := rtl/sync_fifo.v
TB  := tb/tb_sync_fifo.v
TOP := sync_fifo
WIDTH ?= 8
DEPTH ?= 16
PARAMS := -GWIDTH=$(WIDTH) -GDEPTH=$(DEPTH)
CHPARAM := chparam -set WIDTH $(WIDTH) -set DEPTH $(DEPTH) $(TOP)

.PHONY: all sim lint verilator cocotb formal synth schematic clean

all: sim lint verilator cocotb formal synth schematic

build:
	mkdir -p build

sim: | build
	iverilog -g2012 -Ptb_sync_fifo.WIDTH=$(WIDTH) -Ptb_sync_fifo.DEPTH=$(DEPTH) \
		-o build/tb_sync_fifo.vvp $(TB) $(RTL)
	vvp build/tb_sync_fifo.vvp

lint:
	verilator --lint-only -Wall $(PARAMS) --top-module $(TOP) $(RTL)

verilator: | build
	verilator --binary --timing --trace $(PARAMS) --Mdir build/obj_dir \
		--top-module tb_sync_fifo $(TB) $(RTL)
	build/obj_dir/Vtb_sync_fifo

cocotb: | build
	$(MAKE) -C tb WIDTH=$(WIDTH) DEPTH=$(DEPTH)

# Runs the proofs and the cover task in sync_fifo.sby, whatever DEPTH is set to here.
formal: | build
	sby -f --prefix build/formal sync_fifo.sby

# The flags leave out I/O and clock buffers so the counts show only the logic.
synth: | build
	yosys -q -p "read_verilog $(RTL); $(CHPARAM); synth_xilinx -family xc7 -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-xilinx.txt stat"
	yosys -q -p "read_verilog $(RTL); $(CHPARAM); synth_gowin -top $(TOP) -noiopads; tee -o build/stat-gowin.txt stat"
	yosys -q -p "read_verilog $(RTL); $(CHPARAM); synth_intel_alm -family cyclonev -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-cyclonev.txt stat"
	@for family in xilinx gowin cyclonev; do \
		echo "--- $$family"; sed -n '/cells$$/,$$p' build/stat-$$family.txt; \
	done

schematic: | build
	yosys -q -p "read_verilog $(RTL); $(CHPARAM); prep -top $(TOP); show -format png -prefix build/$(TOP)"

clean:
	rm -rf build tb/__pycache__
