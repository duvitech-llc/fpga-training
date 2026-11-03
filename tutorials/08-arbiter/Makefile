RTL := rtl/fixed_arbiter.v rtl/rr_arbiter.v
TB  := tb/tb_rr_arbiter.v
TOP := rr_arbiter
N   ?= 4

.PHONY: all sim lint verilator cocotb formal synth schematic clean

all: sim lint verilator cocotb formal synth schematic

build:
	mkdir -p build

sim: | build
	iverilog -g2012 -Ptb_rr_arbiter.N=$(N) -o build/tb_rr_arbiter.vvp $(TB) $(RTL)
	vvp build/tb_rr_arbiter.vvp

lint:
	verilator --lint-only -Wall -GN=$(N) --top-module $(TOP) $(RTL)

verilator: | build
	verilator --binary --timing --trace -GN=$(N) --Mdir build/obj_dir \
		--top-module tb_rr_arbiter $(TB) $(RTL)
	build/obj_dir/Vtb_rr_arbiter

cocotb: | build
	$(MAKE) -C tb N=$(N)

# Proves N=3, N=4 and N=5, whatever N is set to here.
formal: | build
	sby -f --prefix build/formal rr_arbiter.sby

# The flags leave out I/O and clock buffers so the counts show only the logic.
# synth_xilinx keeps the hierarchy, so flatten afterwards to get one total. Its
# -flatten option crashes this Yosys build at N=4. The other two flatten by default.
synth: | build
	yosys -q -p "read_verilog $(RTL); chparam -set N $(N) $(TOP); synth_xilinx -family xc7 -top $(TOP) -noiopad -noclkbuf; flatten -noscopeinfo; tee -o build/stat-xilinx.txt stat"
	yosys -q -p "read_verilog $(RTL); chparam -set N $(N) $(TOP); synth_gowin -top $(TOP) -noiopads; tee -o build/stat-gowin.txt stat"
	yosys -q -p "read_verilog $(RTL); chparam -set N $(N) $(TOP); synth_intel_alm -family cyclonev -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-cyclonev.txt stat"
	@for family in xilinx gowin cyclonev; do \
		echo "--- $$family"; sed -n '/cells$$/,$$p' build/stat-$$family.txt; \
	done

schematic: | build
	yosys -q -p "read_verilog $(RTL); chparam -set N $(N) $(TOP); prep -top $(TOP); show -format png -prefix build/$(TOP) $(TOP)"

clean:
	rm -rf build tb/__pycache__
