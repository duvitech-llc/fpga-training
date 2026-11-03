RTL := rtl/async_fifo.v rtl/gray_ptr.v
TB  := tb/tb_async_fifo.v
TOP := async_fifo
WIDTH      ?= 8
ADDR_WIDTH ?= 4
PARAMS := chparam -set WIDTH $(WIDTH) -set ADDR_WIDTH $(ADDR_WIDTH) $(TOP)

.PHONY: all sim lint verilator cocotb formal synth schematic clean

all: sim lint verilator cocotb formal synth schematic

build:
	mkdir -p build

sim: | build
	iverilog -g2012 -Ptb_async_fifo.WIDTH=$(WIDTH) -Ptb_async_fifo.ADDR_WIDTH=$(ADDR_WIDTH) \
		-o build/tb_async_fifo.vvp $(TB) $(RTL)
	vvp build/tb_async_fifo.vvp

lint:
	verilator --lint-only -Wall -GWIDTH=$(WIDTH) -GADDR_WIDTH=$(ADDR_WIDTH) \
		--top-module $(TOP) $(RTL)

verilator: | build
	verilator --binary --timing --no-sched-zero-delay --trace \
		-GWIDTH=$(WIDTH) -GADDR_WIDTH=$(ADDR_WIDTH) --Mdir build/obj_dir --top-module tb_async_fifo $(TB) $(RTL)
	build/obj_dir/Vtb_async_fifo

cocotb: | build
	$(MAKE) -C tb WIDTH=$(WIDTH) ADDR_WIDTH=$(ADDR_WIDTH)

# Proves ADDR_WIDTH=2, 3 and 4, whatever ADDR_WIDTH is set to here.
formal: | build
	sby -f --prefix build/formal async_fifo.sby

# The flags leave out I/O and clock buffers so the counts show only the logic.
synth: | build
	yosys -q -p "read_verilog $(RTL); $(PARAMS); synth_xilinx -family xc7 -top $(TOP) -flatten -noiopad -noclkbuf; tee -o build/stat-xilinx.txt stat"
	yosys -q -p "read_verilog $(RTL); $(PARAMS); synth_gowin -top $(TOP) -noiopads; tee -o build/stat-gowin.txt stat"
	yosys -q -p "read_verilog $(RTL); $(PARAMS); synth_intel_alm -family cyclonev -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-cyclonev.txt stat"
	@for family in xilinx gowin cyclonev; do \
		echo "--- $$family"; sed -n '/cells$$/,$$p' build/stat-$$family.txt; \
	done

schematic: | build
	yosys -q -p "read_verilog $(RTL); $(PARAMS); prep -top $(TOP); show -format png -prefix build/$(TOP) $(TOP)"

clean:
	rm -rf build tb/__pycache__
