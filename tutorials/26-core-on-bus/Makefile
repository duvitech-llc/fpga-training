CORE := rtl/rv32i.v rtl/rv_decode.v rtl/rv_alu.v rtl/rv_regs.v rtl/enreg.v
UART := rtl/uart.v rtl/uart_tx.v rtl/uart_rx.v
RTL  := rtl/soc.v $(CORE) rtl/rv_wb_bridge.v rtl/wb_interconnect.v rtl/wb_ram.v \
	rtl/wb_uart.v $(UART) rtl/wb_gpio.v rtl/wb_counters.v rtl/wb_axil_bridge.v rtl/axil_regs.v
PATHS := rtl/rv_wb_bridge.v rtl/wb_interconnect.v rtl/wb_ram.v rtl/wb_axil_bridge.v \
	rtl/axil_regs.v rtl/rv_axil_bridge.v
TOP  := soc
SEED ?= 26
CLKS_PER_BIT ?= 16
PROGRAMS := $(wildcard programs/*.asm)
HEX := $(patsubst programs/%.asm,build/%.hex,$(PROGRAMS))

.PHONY: all asm sim lint verilator cocotb formal synth schematic clean

all: asm sim lint verilator cocotb formal synth schematic

build:
	mkdir -p build

# Tutorial 21's assembler, then the words padded to the full 64 KiB, so that
# $readmemh fills the whole RAM and has nothing to warn about.
build/%.hex: programs/%.asm tools/asm.py tools/pad_hex.py | build
	python3 tools/asm.py $< $@.raw
	python3 tools/pad_hex.py $@.raw $@ 16384

asm: $(HEX)

# The system running every program, then the three paths timed on their own.
sim: asm
	iverilog -g2012 -Irtl -Ptb_soc.CLKS_PER_BIT=$(CLKS_PER_BIT) -o build/tb_soc.vvp tb/tb_soc.v $(RTL)
	vvp -n build/tb_soc.vvp
	iverilog -g2012 -o build/tb_paths.vvp tb/tb_paths.v $(PATHS)
	vvp -n build/tb_paths.vvp

# The whole system, then each new module on its own.
lint:
	verilator --lint-only -Wall -Irtl -GCLKS_PER_BIT=$(CLKS_PER_BIT) --top-module $(TOP) $(RTL)
	verilator --lint-only -Wall --top-module rv_wb_bridge rtl/rv_wb_bridge.v
	verilator --lint-only -Wall --top-module wb_axil_bridge rtl/wb_axil_bridge.v
	verilator --lint-only -Wall --top-module rv_axil_bridge rtl/rv_axil_bridge.v
	verilator --lint-only -Wall --top-module wb_ram rtl/wb_ram.v
	verilator --lint-only -Wall --top-module wb_uart rtl/wb_uart.v $(UART)
	verilator --lint-only -Wall --top-module wb_gpio rtl/wb_gpio.v
	verilator --lint-only -Wall --top-module wb_counters rtl/wb_counters.v

verilator: asm
	verilator --binary --timing --trace -Irtl -GCLKS_PER_BIT=$(CLKS_PER_BIT) --Mdir build/obj_soc \
		--top-module tb_soc tb/tb_soc.v $(RTL) > build/verilator_soc.log
	build/obj_soc/Vtb_soc
	verilator --binary --timing --trace --Mdir build/obj_paths \
		--top-module tb_paths tb/tb_paths.v $(PATHS) > build/verilator_paths.log
	build/obj_paths/Vtb_paths

cocotb: asm
	$(MAKE) -C tb SEED=$(SEED) CLKS_PER_BIT=$(CLKS_PER_BIT)

# The two bridges into Wishbone and AXI4-Lite, the bridge between them, and the
# interconnect with this system's map. A proof and a cover run for each.
formal: | build
	sby -f --prefix build/formal bus.sby
	@echo "$$(grep -l 'DONE (PASS' build/formal_*/logfile.txt | wc -l) tasks passed"

# The flags leave out I/O and clock buffers so the counts show only the logic.
# The bridges alone first, then the whole system with hello.asm in its RAM.
synth: build/hello.hex | build
	@for top in rv_wb_bridge wb_axil_bridge rv_axil_bridge; do \
		yosys -q -p "read_verilog rtl/$$top.v; synth_xilinx -family xc7 -top $$top -noiopad -noclkbuf; tee -o build/stat-xilinx-$$top.txt stat" || exit 1; \
		echo "--- $$top xilinx"; sed -n '/cells$$/,$$p' build/stat-xilinx-$$top.txt; \
	done
	yosys -q -p "read_verilog -Irtl $(RTL); chparam -set INIT \"build/hello.hex\" -set CLKS_PER_BIT $(CLKS_PER_BIT) $(TOP); synth_xilinx -family xc7 -top $(TOP) -noiopad -noclkbuf -flatten; tee -o build/stat-xilinx.txt stat"
	yosys -q -p "read_verilog -Irtl $(RTL); chparam -set INIT \"build/hello.hex\" -set CLKS_PER_BIT $(CLKS_PER_BIT) $(TOP); synth_gowin -top $(TOP) -noiopads; tee -o build/stat-gowin.txt stat"
	yosys -q -p "read_verilog -Irtl $(RTL); chparam -set INIT \"build/hello.hex\" -set CLKS_PER_BIT $(CLKS_PER_BIT) $(TOP); synth_intel_alm -family cyclonev -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-cyclonev.txt stat"
	@for family in xilinx gowin cyclonev; do \
		echo "--- $(TOP) $$family"; sed -n '/cells$$/,$$p' build/stat-$$family.txt; \
	done

# The bridge from the core to Wishbone. The whole system would be unreadable.
schematic: | build
	yosys -q -p "read_verilog rtl/rv_wb_bridge.v; prep -top rv_wb_bridge; show -format png -prefix build/rv_wb_bridge rv_wb_bridge"

clean:
	rm -rf build tb/__pycache__ tools/__pycache__
