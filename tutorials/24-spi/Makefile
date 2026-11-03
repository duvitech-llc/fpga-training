RTL := rtl/shift_reg.v rtl/spi_master.v
TB  := tb/tb_spi.v tb/spi_flash_model.v
TOP := spi_master

.PHONY: all sim lint verilator cocotb formal synth schematic clean

all: sim lint verilator cocotb formal synth schematic

build:
	mkdir -p build

sim: | build
	iverilog -g2012 -o build/tb_spi.vvp $(TB) $(RTL)
	vvp build/tb_spi.vvp

lint:
	verilator --lint-only -Wall --top-module $(TOP) $(RTL)

verilator: | build
	verilator --binary --timing --trace --Mdir build/obj_dir \
		--top-module tb_spi $(TB) $(RTL)
	build/obj_dir/Vtb_spi

cocotb: | build
	$(MAKE) -C tb

# Runs every task in spi.sby.
formal: | build
	sby -f --prefix build/formal spi.sby

# The flags leave out I/O and clock buffers so the counts show only the logic.
# -flatten gives Xilinx one total, with the shift register counted inside.
synth: | build
	yosys -q -p "read_verilog $(RTL); synth_xilinx -family xc7 -top $(TOP) -noiopad -noclkbuf -flatten; tee -o build/stat-xilinx.txt stat"
	yosys -q -p "read_verilog $(RTL); synth_gowin -top $(TOP) -noiopads; tee -o build/stat-gowin.txt stat"
	yosys -q -p "read_verilog $(RTL); synth_intel_alm -family cyclonev -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-cyclonev.txt stat"
	@for family in xilinx gowin cyclonev; do \
		echo "--- $$family"; sed -n '/cells$$/,$$p' build/stat-$$family.txt; \
	done

# The whole master is too tangled to read, so the second picture keeps only the
# shift register and the logic just in front of MOSI, rx_data, sample and launch.
schematic: | build
	yosys -q -p "read_verilog $(RTL); prep -top $(TOP); show -format png -prefix build/$(TOP) $(TOP)"
	yosys -q -p "read_verilog $(RTL); prep -top $(TOP); show -format png -prefix build/datapath w:sample w:launch %u %ci2 w:mosi %ci6 %u w:rx_data %ci4 %u c:u_shift %u"

clean:
	rm -rf build tb/__pycache__
