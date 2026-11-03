RTL := rtl/skid_buffer.v
TB  := tb/tb_skid_buffer.v
TOP := skid_buffer
WIDTH ?= 8

.PHONY: all sim lint verilator cocotb formal synth schematic clean

all: sim lint verilator cocotb formal synth schematic

build:
	mkdir -p build

sim: | build
	iverilog -g2012 -Ptb_skid_buffer.WIDTH=$(WIDTH) -o build/tb_skid_buffer.vvp $(TB) $(RTL)
	vvp build/tb_skid_buffer.vvp

lint:
	verilator --lint-only -Wall -GWIDTH=$(WIDTH) --top-module $(TOP) $(RTL)

verilator: | build
	verilator --binary --timing --trace -GWIDTH=$(WIDTH) --Mdir build/obj_dir \
		--top-module tb_skid_buffer $(TB) $(RTL)
	build/obj_dir/Vtb_skid_buffer

cocotb: | build
	$(MAKE) -C tb WIDTH=$(WIDTH)

# Runs the proofs at WIDTH=8 and WIDTH=32, whatever WIDTH is set to here.
formal: | build
	sby -f --prefix build/formal skid_buffer.sby

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
