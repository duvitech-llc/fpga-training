RTL := rtl/seq_detect.v
TB  := tb/tb_seq_detect.v
TOP := seq_detect

.PHONY: all sim lint verilator cocotb formal synth fsm schematic clean

all: sim lint verilator cocotb formal synth fsm schematic

build:
	mkdir -p build

sim: | build
	iverilog -g2012 -o build/tb_seq_detect.vvp $(TB) $(RTL)
	vvp build/tb_seq_detect.vvp

lint:
	verilator --lint-only -Wall --top-module $(TOP) $(RTL)

verilator: | build
	verilator --binary --timing --trace --Mdir build/obj_dir \
		--top-module tb_seq_detect $(TB) $(RTL)
	build/obj_dir/Vtb_seq_detect

cocotb: | build
	$(MAKE) -C tb

# Runs both tasks in seq_detect.sby: the proof and the cover check.
formal: | build
	sby -f --prefix build/formal seq_detect.sby

# The flags leave out I/O and clock buffers so the counts show only the logic.
synth: | build
	yosys -q -p "read_verilog $(RTL); synth_xilinx -family xc7 -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-xilinx.txt stat"
	yosys -q -p "read_verilog $(RTL); synth_gowin -top $(TOP) -noiopads; tee -o build/stat-gowin.txt stat"
	yosys -q -p "read_verilog $(RTL); synth_intel_alm -family cyclonev -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-cyclonev.txt stat"
	@for family in xilinx gowin cyclonev; do \
		echo "--- $$family"; sed -n '/cells$$/,$$p' build/stat-$$family.txt; \
	done

# Shows what Yosys's FSM passes find, and the state encoding they choose.
fsm: | build
	yosys -p "read_verilog $(RTL); prep -top $(TOP); fsm -nomap" > build/fsm.txt
	sed -n '/Executing FSM_RECODE/,/^End of script/p' build/fsm.txt

schematic: | build
	yosys -q -p "read_verilog $(RTL); prep -top $(TOP); show -format png -prefix build/$(TOP)"

clean:
	rm -rf build tb/__pycache__
