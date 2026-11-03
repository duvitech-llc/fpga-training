RTL   := rtl/sync_ram.v
ASYNC := rtl/async_read_ram.v
TB    := tb/tb_sync_ram.v
TOP   := sync_ram
WIDTH ?= 8
DEPTH ?= 256
PARAMS := chparam -set WIDTH $(WIDTH) -set DEPTH $(DEPTH)

.PHONY: all sim lint verilator cocotb formal formal-huge synth synth-async map schematic clean

all: sim lint verilator cocotb formal formal-huge synth synth-async schematic

build:
	mkdir -p build

sim: | build
	iverilog -g2012 -Ptb_sync_ram.WIDTH=$(WIDTH) -Ptb_sync_ram.DEPTH=$(DEPTH) \
		-o build/tb_sync_ram.vvp $(TB) $(RTL)
	vvp build/tb_sync_ram.vvp

lint:
	verilator --lint-only -Wall -GWIDTH=$(WIDTH) -GDEPTH=$(DEPTH) --top-module $(TOP) $(RTL)
	verilator --lint-only -Wall -GWIDTH=$(WIDTH) -GDEPTH=$(DEPTH) --top-module async_read_ram $(ASYNC)

verilator: | build
	verilator --binary --timing --trace -GWIDTH=$(WIDTH) -GDEPTH=$(DEPTH) --Mdir build/obj_dir \
		--top-module tb_sync_ram $(TB) $(RTL)
	build/obj_dir/Vtb_sync_ram

cocotb: | build
	$(MAKE) -C tb WIDTH=$(WIDTH) DEPTH=$(DEPTH)

# Proves DEPTH=256, 16 and 10, whatever DEPTH is set to here.
formal: | build
	sby -f --prefix build/formal sync_ram.sby d256 d16 d10

# Proves 1M words of 32 bits. Only for a design that passes "make formal": a
# failing proof of this size was still running after 100 seconds.
formal-huge: | build
	sby -f --prefix build/formal sync_ram.sby huge

synth: | build
	$(MAKE) --no-print-directory map MODULE=$(TOP) SOURCE=$(RTL)

synth-async: | build
	$(MAKE) --no-print-directory map MODULE=async_read_ram SOURCE=$(ASYNC)

# The flags leave out I/O and clock buffers so the counts show only the logic.
# FLAGS adds more, such as "make synth FLAGS=-nolutram".
map:
	yosys -q -p "read_verilog $(SOURCE); $(PARAMS) $(MODULE); synth_xilinx -family xc7 -top $(MODULE) -noiopad -noclkbuf $(FLAGS); tee -o build/stat-xilinx.txt stat"
	yosys -q -p "read_verilog $(SOURCE); $(PARAMS) $(MODULE); synth_gowin -top $(MODULE) -noiopads $(FLAGS); tee -o build/stat-gowin.txt stat"
	yosys -q -p "read_verilog $(SOURCE); $(PARAMS) $(MODULE); synth_intel_alm -family cyclonev -top $(MODULE) -noiopad -noclkbuf $(FLAGS); tee -o build/stat-cyclonev.txt stat"
	@for family in xilinx gowin cyclonev; do \
		echo "--- $$family"; sed -n '/cells$$/,$$p' build/stat-$$family.txt; \
	done

schematic: | build
	yosys -q -p "read_verilog $(RTL); $(PARAMS) $(TOP); prep -top $(TOP); show -format png -prefix build/$(TOP)"

clean:
	rm -rf build tb/__pycache__
