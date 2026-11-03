RTL     := rtl/regfile.v rtl/enreg.v
NORESET := rtl/regfile_noreset.v
TB      := tb/tb_regfile.v
TOP     := regfile
WIDTH ?= 8
REGS  ?= 4
TASKS ?= r4 r5 r3 c4 c5
PARAMS := chparam -set WIDTH $(WIDTH) -set REGS $(REGS)

.PHONY: all sim lint verilator cocotb formal synth synth-noreset map schematic clean

all: sim lint verilator cocotb formal synth synth-noreset schematic

build:
	mkdir -p build

sim: | build
	iverilog -g2012 -Ptb_regfile.WIDTH=$(WIDTH) -Ptb_regfile.REGS=$(REGS) \
		-o build/tb_regfile.vvp $(TB) $(RTL)
	vvp build/tb_regfile.vvp

lint:
	verilator --lint-only -Wall -GWIDTH=$(WIDTH) -GREGS=$(REGS) --top-module $(TOP) $(RTL)
	verilator --lint-only -Wall -GWIDTH=$(WIDTH) -GREGS=$(REGS) --top-module regfile_noreset $(NORESET)

verilator: | build
	verilator --binary --timing --trace -GWIDTH=$(WIDTH) -GREGS=$(REGS) --Mdir build/obj_dir \
		--top-module tb_regfile $(TB) $(RTL)
	build/obj_dir/Vtb_regfile

cocotb: | build
	$(MAKE) -C tb WIDTH=$(WIDTH) REGS=$(REGS)

# Proves and covers the REGS values in TASKS, whatever REGS is set to here.
formal: | build
	sby -f --prefix build/formal regfile.sby $(TASKS)

synth: | build
	$(MAKE) --no-print-directory map MODULE=$(TOP) SOURCE="$(RTL)"

synth-noreset: | build
	$(MAKE) --no-print-directory map MODULE=regfile_noreset SOURCE=$(NORESET)

# The flags leave out I/O and clock buffers so the counts show only the logic.
# synth_xilinx keeps the hierarchy unless it is told to flatten, and the other
# two flatten by default. FLAGS adds more, such as "make synth FLAGS=-nolutram".
map:
	yosys -q -p "read_verilog $(SOURCE); $(PARAMS) $(MODULE); synth_xilinx -family xc7 -top $(MODULE) -flatten -noiopad -noclkbuf $(FLAGS); tee -o build/stat-xilinx.txt stat"
	yosys -q -p "read_verilog $(SOURCE); $(PARAMS) $(MODULE); synth_gowin -top $(MODULE) -noiopads $(FLAGS); tee -o build/stat-gowin.txt stat"
	yosys -q -p "read_verilog $(SOURCE); $(PARAMS) $(MODULE); synth_intel_alm -family cyclonev -top $(MODULE) -noiopad -noclkbuf $(FLAGS); tee -o build/stat-cyclonev.txt stat"
	@for family in xilinx gowin cyclonev; do \
		echo "--- $$family"; sed -n '/cells$$/,$$p' build/stat-$$family.txt; \
	done

schematic: | build
	yosys -q -p "read_verilog $(RTL); $(PARAMS) $(TOP); prep -top $(TOP); rename -top $(TOP); show -format png -prefix build/$(TOP) $(TOP)"

clean:
	rm -rf build tb/__pycache__
