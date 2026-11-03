RTL := rtl/axil_regs.v
TB  := tb/tb_axil_regs.v
TOP := axil_regs
# Both slaves by default: 0 waits for AW and W together, 1 buffers each one.
VARIANTS ?= 0 1

.PHONY: all sim lint verilator cocotb formal synth compare-wb schematic clean

all: sim lint verilator cocotb formal synth compare-wb schematic

build:
	mkdir -p build

sim: | build
	@for b in $(VARIANTS); do \
		echo "=== BUFFERED=$$b"; \
		iverilog -g2012 -Ptb_axil_regs.BUFFERED=$$b -o build/tb_axil_regs_$$b.vvp $(TB) $(RTL) || exit 1; \
		vvp -n build/tb_axil_regs_$$b.vvp || exit 1; \
	done

lint:
	@for b in $(VARIANTS); do \
		echo "=== BUFFERED=$$b"; \
		verilator --lint-only -Wall -GBUFFERED=$$b --top-module $(TOP) $(RTL) || exit 1; \
	done

verilator: | build
	@for b in $(VARIANTS); do \
		echo "=== BUFFERED=$$b"; \
		verilator --binary --timing --trace -GBUFFERED=$$b --Mdir build/obj_dir_$$b \
			--top-module tb_axil_regs $(TB) $(RTL) > build/verilator_$$b.log || exit 1; \
		build/obj_dir_$$b/Vtb_axil_regs || exit 1; \
	done

cocotb: | build
	@for b in $(VARIANTS); do \
		$(MAKE) -C tb BUFFERED=$$b || exit 1; \
	done

# Three tasks for each slave: the bus rules, the data, and the covers.
formal: | build
	sby -f --prefix build/formal axi4_lite.sby

# The flags leave out I/O and clock buffers so the counts show only the logic.
synth: | build
	@for b in $(VARIANTS); do \
		yosys -q -p "read_verilog $(RTL); chparam -set BUFFERED $$b $(TOP); synth_xilinx -family xc7 -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-xilinx-$$b.txt stat" || exit 1; \
		yosys -q -p "read_verilog $(RTL); chparam -set BUFFERED $$b $(TOP); synth_gowin -top $(TOP) -noiopads; tee -o build/stat-gowin-$$b.txt stat" || exit 1; \
		yosys -q -p "read_verilog $(RTL); chparam -set BUFFERED $$b $(TOP); synth_intel_alm -family cyclonev -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-cyclonev-$$b.txt stat" || exit 1; \
		for family in xilinx gowin cyclonev; do \
			echo "--- BUFFERED=$$b $$family"; sed -n '/cells$$/,$$p' build/stat-$$family-$$b.txt; \
		done; \
	done

# Only the logic in front of awready, wready and wr_go, back to the nearest
# flip-flops, for each slave. The whole slave would be unreadable.
CONE := w:awready w:wready w:wr_go %u %u %ci*:-$$dff,$$sdff,$$sdffe,$$dffe,$$sdffce,$$mem_v2


# Tutorial 22's Wishbone slave, with four registers like this one, through the
# same Xilinx flow, for the comparison table in the README.
compare-wb: | build
	yosys -q -p "read_verilog ../22-wishbone/rtl/wb_regfile.v; chparam -set AW 2 -set LATENCY 1 wb_regfile; synth_xilinx -family xc7 -top wb_regfile -noiopad -noclkbuf; tee -o build/stat-xilinx-wishbone.txt stat"
	@echo "--- Tutorial 22 wb_regfile, xilinx"; sed -n '/cells$$/,$$p' build/stat-xilinx-wishbone.txt
schematic: | build
	yosys -q -p 'read_verilog $(RTL); chparam -set BUFFERED 0 $(TOP); prep -top $(TOP); show -format png -prefix build/$(TOP)_0 $(CONE)'
	yosys -q -p 'read_verilog $(RTL); chparam -set BUFFERED 1 $(TOP); prep -top $(TOP); show -format png -prefix build/$(TOP)_1 $(CONE)'

clean:
	rm -rf build tb/__pycache__
