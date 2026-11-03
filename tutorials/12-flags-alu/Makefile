RTL := rtl/alu_flags.v
TB  := tb/tb_alu_flags.v
TOP := alu_flags
WIDTH ?= 8
# If not 0, make sim keeps a and b between -SMALL and SMALL-1.
SMALL ?= 0

.PHONY: all sim pitfalls lint verilator cocotb formal synth schematic clean

all: sim pitfalls lint verilator cocotb formal synth schematic

build:
	mkdir -p build

sim: | build
	iverilog -g2012 -Ptb_alu_flags.WIDTH=$(WIDTH) -Ptb_alu_flags.SMALL=$(SMALL) \
		-o build/tb_alu_flags.vvp $(TB) $(RTL)
	vvp build/tb_alu_flags.vvp

# Under Icarus and then Verilator, which must agree. The file mixes widths on purpose,
# so Verilator's width warnings are turned off for it.
pitfalls: | build
	iverilog -g2012 -o build/signed_pitfalls.vvp tb/signed_pitfalls.v
	vvp build/signed_pitfalls.vvp
	verilator --binary -Wno-WIDTHEXPAND --Mdir build/obj_pitfalls \
		--top-module signed_pitfalls tb/signed_pitfalls.v > build/verilator_pitfalls.log
	build/obj_pitfalls/Vsigned_pitfalls

lint:
	verilator --lint-only -Wall -GWIDTH=$(WIDTH) --top-module $(TOP) $(RTL)

# No --trace: Verilator ignores $dumpoff, so it would write a 224 MB waveform.
verilator: | build
	verilator --binary --timing -GWIDTH=$(WIDTH) -GSMALL=$(SMALL) --Mdir build/obj_dir \
		--top-module tb_alu_flags $(TB) $(RTL)
	build/obj_dir/Vtb_alu_flags

cocotb: | build
	$(MAKE) -C tb WIDTH=$(WIDTH)

# Proves WIDTH=8 and WIDTH=32, whatever WIDTH is set to here.
formal: | build
	sby -f --prefix build/formal alu_flags.sby

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
