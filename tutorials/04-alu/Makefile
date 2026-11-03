RTL := rtl/alu.v
TB  := tb/tb_alu.v
TOP := alu
WIDTH ?= 8
# The testbench tries every input, so it runs at a smaller width.
SIM_WIDTH ?= 4

.PHONY: all sim lint verilator cocotb formal synth schematic clean

all: sim lint verilator cocotb formal synth schematic

build:
	mkdir -p build

sim: | build
	iverilog -g2012 -Ptb_alu.WIDTH=$(SIM_WIDTH) -o build/tb_alu.vvp $(TB) $(RTL)
	vvp build/tb_alu.vvp

lint:
	verilator --lint-only -Wall -GWIDTH=$(WIDTH) --top-module $(TOP) $(RTL)

verilator: | build
	verilator --binary --timing --trace -GWIDTH=$(SIM_WIDTH) --Mdir build/obj_dir \
		--top-module tb_alu $(TB) $(RTL)
	build/obj_dir/Vtb_alu

cocotb: | build
	$(MAKE) -C tb WIDTH=$(WIDTH)

# Proves WIDTH=8 and WIDTH=32, whatever WIDTH is set to here.
formal: | build
	sby -f --prefix build/formal alu.sby

# The flags leave out I/O and clock buffers so the counts show only the logic.
synth: | build
	yosys -q -p "read_verilog $(RTL); chparam -set WIDTH $(WIDTH) $(TOP); synth_xilinx -family xc7 -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-xilinx.txt stat"
	yosys -q -p "read_verilog $(RTL); chparam -set WIDTH $(WIDTH) $(TOP); synth_gowin -top $(TOP) -noiopads; tee -o build/stat-gowin.txt stat"
	yosys -q -p "read_verilog $(RTL); chparam -set WIDTH $(WIDTH) $(TOP); synth_intel_alm -family cyclonev -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-cyclonev.txt stat"
	@for family in xilinx gowin cyclonev; do \
		echo "--- $$family"; sed -n '/cells$$/,$$p' build/stat-$$family.txt; \
	done

schematic: | build
	yosys -q -p "read_verilog $(RTL); chparam -set WIDTH $(WIDTH) $(TOP); prep -top $(TOP); show -format png -prefix build/$(TOP)"

clean:
	rm -rf build tb/__pycache__
