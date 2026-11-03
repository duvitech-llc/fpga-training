LFSR_RTL := rtl/lfsr_fib.v rtl/lfsr_galois.v
CRC_RTL  := rtl/crc32_serial.v rtl/crc32_byte.v rtl/crc32_byte_xor.v
RTL      := $(LFSR_RTL) $(CRC_RTL)
DESIGNS  := lfsr_fib lfsr_galois crc32_serial crc32_byte crc32_byte_xor

.PHONY: all equations sim lint verilator cocotb formal synth schematic clean

all: equations sim lint verilator cocotb formal synth schematic

build:
	mkdir -p build

# Derives the byte-parallel equations again, and fails if they differ from the
# ones in rtl/crc32_byte_xor.v.
equations: | build
	python3 tools/crc_parallel.py
	python3 tools/crc_parallel.py verilog > build/crc32_byte_xor.v
	diff build/crc32_byte_xor.v rtl/crc32_byte_xor.v && echo "rtl/crc32_byte_xor.v is up to date"

sim: | build
	iverilog -g2012 -o build/tb_lfsr.vvp tb/tb_lfsr.v $(LFSR_RTL)
	vvp build/tb_lfsr.vvp
	iverilog -g2012 -o build/tb_crc.vvp tb/tb_crc.v $(CRC_RTL)
	vvp build/tb_crc.vvp

lint:
	@for top in $(DESIGNS); do \
		echo "--- $$top"; \
		verilator --lint-only -Wall --top-module $$top $(RTL) || exit 1; \
	done

# No --trace for the LFSRs: Verilator ignores $dumpoff, and would record the
# 65535-clock run as well.
verilator: | build
	verilator --binary --timing --Mdir build/obj_lfsr --top-module tb_lfsr tb/tb_lfsr.v $(LFSR_RTL)
	build/obj_lfsr/Vtb_lfsr
	verilator --binary --timing --trace --Mdir build/obj_crc --top-module tb_crc tb/tb_crc.v $(CRC_RTL)
	build/obj_crc/Vtb_crc

cocotb: | build
	$(MAKE) -C tb DESIGN=crc32_byte
	$(MAKE) -C tb DESIGN=crc32_byte_xor
	$(MAKE) -C tb DESIGN=crc32_serial

formal: | build
	sby -f --prefix build/formal crc.sby

# The flags leave out I/O and clock buffers so the counts show only the logic.
synth: | build
	@for top in $(DESIGNS); do \
		yosys -q -p "read_verilog $(RTL); synth_xilinx -family xc7 -top $$top -noiopad -noclkbuf; tee -q -o build/stat-xilinx-$$top.txt stat" || exit 1; \
		yosys -q -p "read_verilog $(RTL); synth_gowin -top $$top -noiopads; tee -q -o build/stat-gowin-$$top.txt stat" || exit 1; \
		yosys -q -p "read_verilog $(RTL); synth_intel_alm -family cyclonev -top $$top -noiopad -noclkbuf; tee -q -o build/stat-cyclonev-$$top.txt stat" || exit 1; \
	done
	@for top in $(DESIGNS); do \
		for family in xilinx gowin cyclonev; do \
			echo "--- $$top $$family"; sed -n '/cells$$/,$$p' build/stat-$$family-$$top.txt; \
		done; \
	done

# A 4-bit Galois LFSR, small enough to read. The CRCs are a wall of XOR gates.
schematic: | build
	yosys -q -p "read_verilog rtl/lfsr_galois.v; chparam -set WIDTH 4 -set POLY 4'b0011 lfsr_galois; prep -top lfsr_galois; show -format png -prefix build/lfsr_galois"
	yosys -q -p "read_verilog rtl/crc32_serial.v; prep -top crc32_serial; show -format png -prefix build/crc32_serial"

clean:
	rm -rf build tb/__pycache__ tb/results.xml
