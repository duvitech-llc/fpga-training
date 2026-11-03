RTL := rtl/counter.v
TB  := tb/tb_counter.v
TOP := counter
MOD ?= 10

.PHONY: all sim lint verilator cocotb formal synth schematic clean

all: sim lint verilator cocotb formal synth schematic

build:
	mkdir -p build

sim: | build
	iverilog -g2012 -Ptb_counter.MOD=$(MOD) -o build/tb_counter.vvp $(TB) $(RTL)
	vvp build/tb_counter.vvp

lint:
	verilator --lint-only -Wall -GMOD=$(MOD) --top-module $(TOP) $(RTL)

verilator: | build
	verilator --binary --timing --trace -GMOD=$(MOD) --Mdir build/obj_dir \
		--top-module tb_counter $(TB) $(RTL)
	build/obj_dir/Vtb_counter

cocotb: | build
	$(MAKE) -C tb MOD=$(MOD)

# Proves MOD=10 and MOD=16, whatever MOD is set to here.
formal: | build
	sby -f --prefix build/formal counter.sby

# The flags leave out I/O and clock buffers so the counts show only the logic.
synth: | build
	yosys -q -p "read_verilog $(RTL); chparam -set MOD $(MOD) $(TOP); synth_xilinx -family xc7 -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-xilinx.txt stat"
	yosys -q -p "read_verilog $(RTL); chparam -set MOD $(MOD) $(TOP); synth_gowin -top $(TOP) -noiopads; tee -o build/stat-gowin.txt stat"
	yosys -q -p "read_verilog $(RTL); chparam -set MOD $(MOD) $(TOP); synth_intel_alm -family cyclonev -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-cyclonev.txt stat"
	@for family in xilinx gowin cyclonev; do \
		echo "--- $$family"; sed -n '/cells$$/,$$p' build/stat-$$family.txt; \
	done

schematic: | build
	yosys -q -p "read_verilog $(RTL); chparam -set MOD $(MOD) $(TOP); prep -top $(TOP); show -format png -prefix build/$(TOP)"

clean:
	rm -rf build tb/__pycache__
