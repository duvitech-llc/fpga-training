RTL := rtl/computer.v rtl/bus.v rtl/cpu.v rtl/decode.v rtl/alu_flags.v rtl/regfile.v \
	rtl/enreg.v rtl/uart.v rtl/uart_tx.v rtl/uart_rx.v
TB  := tb/tb_computer.v
TOP := computer
CLKS_PER_BIT ?= 16
PROGRAMS := $(wildcard programs/*.asm)
HEX := $(patsubst programs/%.asm,build/%.hex,$(PROGRAMS))

.PHONY: all asm sim lint verilator cocotb formal synth schematic pnr clean

all: asm sim lint verilator cocotb formal synth schematic pnr

build:
	mkdir -p build

build/%.hex: programs/%.asm tools/asm.py | build
	python3 tools/asm.py $< $@

asm: $(HEX)

sim: asm
	iverilog -g2012 -Ptb_computer.CLKS_PER_BIT=$(CLKS_PER_BIT) -o build/tb_computer.vvp $(TB) $(RTL)
	vvp build/tb_computer.vvp

lint:
	verilator --lint-only -Wall -GCLKS_PER_BIT=$(CLKS_PER_BIT) --top-module $(TOP) $(RTL)

verilator: asm
	verilator --binary --timing --trace -GCLKS_PER_BIT=$(CLKS_PER_BIT) --Mdir build/obj_dir \
		--top-module tb_computer $(TB) $(RTL)
	build/obj_dir/Vtb_computer

cocotb: asm
	$(MAKE) -C tb CLKS_PER_BIT=$(CLKS_PER_BIT)

# Two tasks on bus alone: the proof, and cover. The computer as a whole is not proved.
formal: | build
	sby -f --prefix build/formal bus.sby

# The flags leave out I/O and clock buffers so the counts show only the logic.
# -flatten gives Xilinx one total for the whole computer. The other two flatten anyway.
synth: build/hello.hex | build
	yosys -q -p "read_verilog $(RTL); chparam -set PROGRAM \"build/hello.hex\" -set CLKS_PER_BIT $(CLKS_PER_BIT) $(TOP); synth_xilinx -family xc7 -top $(TOP) -noiopad -noclkbuf -flatten; tee -o build/stat-xilinx.txt stat"
	yosys -q -p "read_verilog $(RTL); chparam -set PROGRAM \"build/hello.hex\" -set CLKS_PER_BIT $(CLKS_PER_BIT) $(TOP); synth_gowin -top $(TOP) -noiopads; tee -o build/stat-gowin.txt stat"
	yosys -q -p "read_verilog $(RTL); chparam -set PROGRAM \"build/hello.hex\" -set CLKS_PER_BIT $(CLKS_PER_BIT) $(TOP); synth_intel_alm -family cyclonev -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-cyclonev.txt stat"
	@for family in xilinx gowin cyclonev; do \
		echo "--- $$family"; sed -n '/cells$$/,$$p' build/stat-$$family.txt; \
	done

# The bus alone. The whole computer would be unreadable.
schematic: | build
	yosys -q -p "read_verilog rtl/bus.v; prep -top bus; show -format png -prefix build/bus bus"

# An open-source estimate for a Gowin GW1N-9C. This is not a vendor result.
pnr: build/hello.hex | build
	yosys -q -p "read_verilog $(RTL); chparam -set PROGRAM \"build/hello.hex\" -set CLKS_PER_BIT $(CLKS_PER_BIT) $(TOP); synth_gowin -top $(TOP) -json build/top.json; tee -o build/stat-top.txt stat"
	@for seed in 1 2 3 4 5; do \
		nextpnr-himbaechel --device GW1NR-LV9QN88PC6/I5 --vopt family=GW1N-9C \
			--vopt cst=computer.cst --json build/top.json --freq 25 \
			--seed $$seed --threads 1 > build/pnr-$$seed.log 2>&1 || exit 1; \
		echo "seed=$$seed: $$(grep 'Max frequency' build/pnr-$$seed.log | tail -1 | sed 's/.*: *//')"; \
	done

clean:
	rm -rf build tb/__pycache__ tools/__pycache__
