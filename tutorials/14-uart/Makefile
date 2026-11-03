RTL := rtl/uart_tx.v rtl/uart_rx.v rtl/uart.v
TB  := tb/tb_uart.v
TOP := uart
CLKS_PER_BIT ?= 16

.PHONY: all sim lint verilator cocotb formal synth schematic clean

all: sim lint verilator cocotb formal synth schematic

build:
	mkdir -p build

sim: | build
	iverilog -g2012 -Ptb_uart.CLKS_PER_BIT=$(CLKS_PER_BIT) -o build/tb_uart.vvp $(TB) $(RTL)
	vvp build/tb_uart.vvp

lint:
	verilator --lint-only -Wall -GCLKS_PER_BIT=$(CLKS_PER_BIT) --top-module $(TOP) $(RTL)

verilator: | build
	verilator --binary --timing --trace -GCLKS_PER_BIT=$(CLKS_PER_BIT) --Mdir build/obj_dir \
		--top-module tb_uart $(TB) $(RTL)
	build/obj_dir/Vtb_uart

cocotb: | build
	$(MAKE) -C tb CLKS_PER_BIT=$(CLKS_PER_BIT)

# Runs every task in uart.sby, whatever CLKS_PER_BIT is set to here.
formal: | build
	sby -f --prefix build/formal uart.sby

# The flags leave out I/O and clock buffers so the counts show only the logic.
# -flatten gives Xilinx one total for both halves. The other two flatten anyway.
synth: | build
	yosys -q -p "read_verilog $(RTL); chparam -set CLKS_PER_BIT $(CLKS_PER_BIT) $(TOP); synth_xilinx -family xc7 -top $(TOP) -noiopad -noclkbuf -flatten; tee -o build/stat-xilinx.txt stat"
	yosys -q -p "read_verilog $(RTL); chparam -set CLKS_PER_BIT $(CLKS_PER_BIT) $(TOP); synth_gowin -top $(TOP) -noiopads; tee -o build/stat-gowin.txt stat"
	yosys -q -p "read_verilog $(RTL); chparam -set CLKS_PER_BIT $(CLKS_PER_BIT) $(TOP); synth_intel_alm -family cyclonev -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-cyclonev.txt stat"
	@for family in xilinx gowin cyclonev; do \
		echo "--- $$family"; sed -n '/cells$$/,$$p' build/stat-$$family.txt; \
	done

schematic: | build
	yosys -q -p "read_verilog $(RTL); chparam -set CLKS_PER_BIT $(CLKS_PER_BIT) uart_rx; prep -top uart_rx; show -format png -prefix build/uart_rx"

clean:
	rm -rf build tb/__pycache__
