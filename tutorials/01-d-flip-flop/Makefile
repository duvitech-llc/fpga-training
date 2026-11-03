RTL := rtl/dff.v
TB  := tb/tb_dff.v
TOP := dff

.PHONY: all sim lint verilator cocotb formal synth schematic clean

all: sim lint verilator cocotb formal synth schematic

build:
	mkdir -p build

sim: | build
	iverilog -g2012 -o build/tb_dff.vvp $(TB) $(RTL)
	vvp build/tb_dff.vvp

lint:
	verilator --lint-only -Wall --top-module $(TOP) $(RTL)

verilator: | build
	verilator --binary --timing --trace --Mdir build/obj_dir \
		--top-module tb_dff $(TB) $(RTL)
	build/obj_dir/Vtb_dff

cocotb: | build
	$(MAKE) -C tb

formal: | build
	sby -f -d build/formal dff.sby

# The flags leave out I/O and clock buffers so the counts show only the logic.
synth: | build
	yosys -q -p "read_verilog $(RTL); synth_xilinx -family xc7 -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-xilinx.txt stat"
	yosys -q -p "read_verilog $(RTL); synth_gowin -top $(TOP) -noiopads; tee -o build/stat-gowin.txt stat"
	yosys -q -p "read_verilog $(RTL); synth_intel_alm -family cyclonev -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-cyclonev.txt stat"
	@for family in xilinx gowin cyclonev; do \
		echo "--- $$family"; sed -n '/cells$$/,$$p' build/stat-$$family.txt; \
	done

schematic: | build
	yosys -q -p "read_verilog $(RTL); prep -top $(TOP); show -format png -prefix build/$(TOP)"

clean:
	rm -rf build tb/__pycache__
