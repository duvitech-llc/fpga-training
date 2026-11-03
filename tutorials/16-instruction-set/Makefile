RTL := rtl/decode.v
TB  := tb/tb_decode.v
TOP := decode

.PHONY: all asm sim lint verilator cocotb formal synth schematic clean

all: asm sim lint verilator cocotb formal synth schematic

build:
	mkdir -p build

# Tests the assembler, then assembles the example program with a listing.
asm: | build
	python3 tools/test_asm.py
	python3 tools/asm.py programs/demo.asm build/demo.hex --list

sim: | build
	iverilog -g2012 -o build/tb_decode.vvp $(TB) $(RTL)
	vvp build/tb_decode.vvp

lint:
	verilator --lint-only -Wall --top-module $(TOP) $(RTL)

# No --trace: Verilator ignores $dumpoff, so it would record the whole test.
verilator: | build
	verilator --binary --timing --Mdir build/obj_dir \
		--top-module tb_decode $(TB) $(RTL)
	build/obj_dir/Vtb_decode

cocotb: | build
	$(MAKE) -C tb

formal: | build
	sby -f --prefix build/formal decode.sby

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
	rm -rf build tb/__pycache__ tools/__pycache__
