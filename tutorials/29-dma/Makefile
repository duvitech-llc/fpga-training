CORE := rtl/rv32i.v rtl/rv_decode.v rtl/rv_alu.v rtl/rv_regs.v rtl/enreg.v
UART := rtl/uart.v rtl/uart_tx.v rtl/uart_rx.v
ARB  := rtl/wb_arbiter.v rtl/rr_arbiter.v rtl/fixed_arbiter.v
RTL  := rtl/soc.v $(CORE) rtl/rv_wb_bridge.v $(ARB) rtl/wb_dma.v rtl/wb_interconnect.v \
	rtl/wb_ram.v rtl/wb_uart.v $(UART) rtl/wb_gpio.v rtl/wb_counters.v rtl/wb_axil_bridge.v \
	rtl/axil_regs.v
TOP  := soc
SEED ?= 29
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

sim: asm
	iverilog -g2012 -Irtl -Ptb_soc.CLKS_PER_BIT=$(CLKS_PER_BIT) -o build/tb_soc.vvp tb/tb_soc.v $(RTL)
	vvp -n build/tb_soc.vvp

# The whole system, then each new module on its own.
lint:
	verilator --lint-only -Wall -Irtl -GCLKS_PER_BIT=$(CLKS_PER_BIT) --top-module $(TOP) $(RTL)
	verilator --lint-only -Wall --top-module wb_arbiter $(ARB)
	verilator --lint-only -Wall -GN=3 --top-module wb_arbiter $(ARB)
	verilator --lint-only -Wall --top-module wb_dma rtl/wb_dma.v
	verilator --lint-only -Wall --top-module wb_uart rtl/wb_uart.v $(UART)

verilator: asm
	verilator --binary --timing -Irtl -GCLKS_PER_BIT=$(CLKS_PER_BIT) --Mdir build/obj_soc \
		--top-module tb_soc tb/tb_soc.v $(RTL) > build/verilator_soc.log
	build/obj_soc/Vtb_soc

cocotb: asm
	$(MAKE) -C tb SEED=$(SEED) CLKS_PER_BIT=$(CLKS_PER_BIT)

# The arbiter at N=2 and N=3, the DMA engine, and the interconnect with this
# system's map. A proof and a cover run for each.
formal: | build
	sby -f --prefix build/formal dma.sby
	@echo "$$(grep -l 'DONE (PASS' build/formal_*/logfile.txt | wc -l) tasks passed"

# The flags leave out I/O and clock buffers so the counts show only the logic.
# The two new modules alone first, then the whole system with hello.asm in its RAM.
synth: build/hello.hex | build
	yosys -q -p "read_verilog $(ARB); synth_xilinx -family xc7 -top wb_arbiter -noiopad -noclkbuf -flatten; tee -o build/stat-xilinx-wb_arbiter.txt stat"
	yosys -q -p "read_verilog rtl/wb_dma.v; synth_xilinx -family xc7 -top wb_dma -noiopad -noclkbuf -flatten; tee -o build/stat-xilinx-wb_dma.txt stat"
	@for top in wb_arbiter wb_dma; do \
		echo "--- $$top xilinx"; sed -n '/cells$$/,$$p' build/stat-xilinx-$$top.txt; \
	done
	yosys -q -p "read_verilog -Irtl $(RTL); chparam -set INIT \"build/hello.hex\" -set CLKS_PER_BIT $(CLKS_PER_BIT) $(TOP); synth_xilinx -family xc7 -top $(TOP) -noiopad -noclkbuf -flatten; tee -o build/stat-xilinx.txt stat"
	yosys -q -p "read_verilog -Irtl $(RTL); chparam -set INIT \"build/hello.hex\" -set CLKS_PER_BIT $(CLKS_PER_BIT) $(TOP); synth_gowin -top $(TOP) -noiopads; tee -o build/stat-gowin.txt stat"
	yosys -q -p "read_verilog -Irtl $(RTL); chparam -set INIT \"build/hello.hex\" -set CLKS_PER_BIT $(CLKS_PER_BIT) $(TOP); synth_intel_alm -family cyclonev -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-cyclonev.txt stat"
	@for family in xilinx gowin cyclonev; do \
		echo "--- $(TOP) $$family"; sed -n '/cells$$/,$$p' build/stat-$$family.txt; \
	done

# The arbiter, with Tutorial 8's arbiter inside it as a box. The whole system
# would be unreadable.
schematic: | build
	yosys -q -p "read_verilog $(ARB); prep -top wb_arbiter; show -format png -prefix build/wb_arbiter wb_arbiter"

clean:
	rm -rf build tb/__pycache__ tools/__pycache__
