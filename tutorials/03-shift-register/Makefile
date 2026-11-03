RTL := rtl/shift_reg.v
TB  := tb/tb_shift_reg.v
TOP := shift_reg
WIDTH ?= 8

.PHONY: all sim chain lint verilator cocotb formal synth schematic clean

all: sim chain lint verilator cocotb formal synth schematic

build:
	mkdir -p build

sim: | build
	iverilog -g2012 -Ptb_shift_reg.WIDTH=$(WIDTH) -o build/tb_shift_reg.vvp $(TB) $(RTL)
	vvp build/tb_shift_reg.vvp

# The simulation comes last because when it fails it stops make.
chain: | build
	yosys -q -p "read_verilog rtl/chain.v; prep -top chain; show -format png -prefix build/chain"
	yosys -q -p "read_verilog rtl/chain.v; synth_xilinx -family xc7 -top chain -noiopad -noclkbuf; tee -o build/stat-chain.txt stat"
	@sed -n '/cells$$/,$$p' build/stat-chain.txt
	iverilog -g2012 -o build/tb_chain.vvp tb/tb_chain.v rtl/chain.v
	vvp build/tb_chain.vvp

lint:
	verilator --lint-only -Wall -GWIDTH=$(WIDTH) --top-module $(TOP) $(RTL)
	verilator --lint-only -Wall --top-module chain rtl/chain.v

verilator: | build
	verilator --binary --timing --trace -GWIDTH=$(WIDTH) --Mdir build/obj_dir \
		--top-module tb_shift_reg $(TB) $(RTL)
	build/obj_dir/Vtb_shift_reg
	verilator --binary --timing --trace --Mdir build/obj_chain \
		--top-module tb_chain tb/tb_chain.v rtl/chain.v
	build/obj_chain/Vtb_chain

cocotb: | build
	$(MAKE) -C tb WIDTH=$(WIDTH)

# Proves WIDTH=2 and WIDTH=8, whatever WIDTH is set to here.
formal: | build
	sby -f --prefix build/formal shift_reg.sby

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
