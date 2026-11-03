RTL  := rtl/sync_2ff.v rtl/pulse_sync.v rtl/reset_sync.v
TOPS := sync_2ff pulse_sync reset_sync
TB   := tb/tb_cdc.v tb/cdc_top.v

.PHONY: all sim lint verilator cocotb formal synth schematic clean

all: sim lint verilator cocotb formal synth schematic

build:
	mkdir -p build

# Top: tb_cdc, which holds all three modules through tb/cdc_top.v.
sim: | build
	iverilog -g2012 -s tb_cdc -o build/tb_cdc.vvp $(TB) $(RTL)
	vvp build/tb_cdc.vvp

# Tops: each module in turn.
lint:
	@for top in $(TOPS); do \
		echo "--- $$top"; \
		verilator --lint-only -Wall --top-module $$top $(RTL) || exit 1; \
	done

# Top: tb_cdc, the same testbench as sim.
verilator: | build
	verilator --binary --timing --no-sched-zero-delay --trace --Mdir build/obj_dir \
		--top-module tb_cdc $(TB) $(RTL)
	build/obj_dir/Vtb_cdc

# Top: cdc_top, which holds all three modules, so one run covers them all.
cocotb: | build
	$(MAKE) -C tb

# Tops: each module in turn, set per task in cdc_reset.sby.
formal: | build
	sby -f --prefix build/formal cdc_reset.sby

# Tops: each module in turn.
# The flags leave out I/O and clock buffers so the counts show only the logic.
synth: | build
	@for top in $(TOPS); do \
		yosys -q -p "read_verilog $(RTL); synth_xilinx -family xc7 -top $$top -flatten -noiopad -noclkbuf; tee -o build/stat-$$top-xilinx.txt stat" || exit 1; \
		yosys -q -p "read_verilog $(RTL); synth_gowin -top $$top -noiopads; tee -o build/stat-$$top-gowin.txt stat" || exit 1; \
		yosys -q -p "read_verilog $(RTL); synth_intel_alm -family cyclonev -top $$top -noiopad -noclkbuf; tee -o build/stat-$$top-cyclonev.txt stat" || exit 1; \
		for family in xilinx gowin cyclonev; do \
			echo "--- $$top $$family"; sed -n '/cells$$/,$$p' build/stat-$$top-$$family.txt; \
		done; \
	done

# Top: pulse_sync, flattened so that sync_2ff shows as flops and not as a box.
schematic: | build
	yosys -q -p "read_verilog $(RTL); prep -flatten -top pulse_sync; show -format png -prefix build/pulse_sync pulse_sync"

clean:
	rm -rf build tb/__pycache__
