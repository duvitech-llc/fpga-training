RTL := rtl/wb_system.v rtl/wb_master.v rtl/wb_interconnect.v rtl/wb_regfile.v
TB  := tb/tb_wishbone.v
TOP := wb_system

.PHONY: all sim lint verilator cocotb formal synth schematic clean

all: sim lint verilator cocotb formal synth schematic

build:
	mkdir -p build

sim: | build
	iverilog -g2012 -o build/tb_wishbone.vvp $(TB) $(RTL)
	vvp build/tb_wishbone.vvp

# The whole system, then each reusable module on its own with its default parameters.
lint:
	verilator --lint-only -Wall --top-module $(TOP) $(RTL)
	verilator --lint-only -Wall --top-module wb_interconnect rtl/wb_interconnect.v
	verilator --lint-only -Wall --top-module wb_regfile rtl/wb_regfile.v
	verilator --lint-only -Wall --top-module wb_master rtl/wb_master.v

verilator: | build
	verilator --binary --timing --trace --Mdir build/obj_dir \
		--top-module tb_wishbone $(TB) $(RTL)
	build/obj_dir/Vtb_wishbone

cocotb: | build
	$(MAKE) -C tb

# Seven tasks: a proof and a cover run for each of the slave, the interconnect and
# the master, and one more proof of the slave with LATENCY at 1.
formal: | build
	sby -f --prefix build/formal wishbone.sby

# The flags leave out I/O and clock buffers so the counts show only the logic.
# The interconnect alone first, since it is the part a later system reuses, then everything.
synth: | build
	@for top in wb_interconnect $(TOP); do \
		yosys -q -p "read_verilog $(RTL); synth_xilinx -family xc7 -top $$top -noiopad -noclkbuf -flatten; tee -o build/stat-xilinx-$$top.txt stat" || exit 1; \
		yosys -q -p "read_verilog $(RTL); synth_gowin -top $$top -noiopads; tee -o build/stat-gowin-$$top.txt stat" || exit 1; \
		yosys -q -p "read_verilog $(RTL); synth_intel_alm -family cyclonev -top $$top -noiopad -noclkbuf; tee -o build/stat-cyclonev-$$top.txt stat" || exit 1; \
		for family in xilinx gowin cyclonev; do \
			echo "--- $$top $$family"; sed -n '/cells$$/,$$p' build/stat-$$family-$$top.txt; \
		done; \
	done

# The interconnect alone. The whole system would be unreadable.
schematic: | build
	yosys -q -p "read_verilog rtl/wb_interconnect.v; prep -top wb_interconnect; show -format png -prefix build/wb_interconnect wb_interconnect"

clean:
	rm -rf build tb/__pycache__
