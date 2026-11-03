CORE := rtl/rv32i.v rtl/rv_decode.v rtl/rv_alu.v rtl/rv_regs.v rtl/enreg.v
XIP  := rtl/wb_xip.v rtl/spi_master.v rtl/shift_reg.v
RTL  := rtl/soc.v $(CORE) rtl/icache.v rtl/rv_wb_bridge.v rtl/wb_interconnect.v rtl/wb_ram.v \
	rtl/wb_gpio.v rtl/wb_counters.v rtl/wb_cachectl.v $(XIP)
TB   := tb/tb_icache.v tb/spi_flash_model.v
TOP  := soc
SEED ?= 30

# The programs: two written by hand, two written by tools/gen_programs.py, and
# the jump that starts a program in flash.
PROGRAMS := tight straight bigloop selfmod
IMAGES   := $(foreach p,$(PROGRAMS),build/$(p).hex build/flash_$(p).hex) build/jump_to_flash.hex

# Caches to time with make measure: lines:words per line:stream. 0 lines is no
# cache. Stream 1 keeps the flash's read open for the next word.
CONFIGS := 0:4:0 0:4:1 16:4:1 64:1:1 64:4:1 32:8:1 256:1:1 256:4:1 64:4:0

.PHONY: all images sim measure lint verilator cocotb formal synth schematic clean

# Keep the assembled words, which the cocotb test reads too.
.SECONDARY:

all: images sim measure lint verilator cocotb formal synth schematic

build:
	mkdir -p build

# ----- Programs -----

build/straight.asm build/bigloop.asm: tools/gen_programs.py | build
	python3 tools/gen_programs.py build

# Tutorial 21's assembler. Every program is assembled from address 0.
build/%.raw: programs/%.asm tools/asm.py | build
	python3 tools/asm.py $< $@ --list > build/$*.lst
build/%.raw: build/%.asm tools/asm.py
	python3 tools/asm.py $< $@ --list > build/$*.lst

# For RAM: padded to 64 KiB, so $readmemh fills the whole RAM.
build/%.hex: build/%.raw tools/pad_hex.py
	python3 tools/pad_hex.py $< $@ 16384

# For the flash: bytes, the program at flash address 0.
build/flash_%.hex: build/%.raw tools/flash_hex.py
	python3 tools/flash_hex.py $< $@

images: $(IMAGES)

# ----- Checks -----

sim: images
	iverilog -g2012 -Irtl -o build/tb_icache.vvp $(TB) $(RTL)
	vvp -n build/tb_icache.vvp +waves

# Each cache in CONFIGS, timed on every program from RAM and from the flash. The
# lines go to build/measure_*.log, and tools/tables.py prints the tables.
measure: images
	@for c in $(CONFIGS); do \
		set -- $$(echo $$c | tr : ' '); \
		iverilog -g2012 -Irtl -Ptb_icache.CACHE_LINES=$$1 -Ptb_icache.CACHE_LINE_WORDS=$$2 \
			-Ptb_icache.XIP_STREAM=$$3 -o build/measure.vvp $(TB) $(RTL) || exit 1; \
		vvp -n build/measure.vvp +measure > build/measure_$$1_$$2_$$3.log; \
		grep -E "^(FAIL|PASS)" build/measure_$$1_$$2_$$3.log | tail -1; \
		grep -q "^PASS" build/measure_$$1_$$2_$$3.log || { cat build/measure_$$1_$$2_$$3.log; exit 1; }; \
	done
	python3 tools/tables.py build/measure_*.log

# The whole system, then each new module on its own.
lint:
	verilator --lint-only -Wall -Irtl --top-module $(TOP) $(RTL)
	verilator --lint-only -Wall -Irtl -GCACHE_LINES=0 --top-module $(TOP) $(RTL)
	verilator --lint-only -Wall --top-module icache rtl/icache.v
	verilator --lint-only -Wall -GLINE_WORDS=1 --top-module icache rtl/icache.v
	verilator --lint-only -Wall --top-module wb_xip $(XIP)
	verilator --lint-only -Wall -GSTREAM=0 --top-module wb_xip $(XIP)
	verilator --lint-only -Wall --top-module wb_cachectl rtl/wb_cachectl.v

verilator: images
	verilator --binary --timing --trace -Irtl --Mdir build/obj_icache \
		--top-module tb_icache $(TB) $(RTL) > build/verilator_icache.log
	build/obj_icache/Vtb_icache

cocotb: images
	$(MAKE) -C tb SEED=$(SEED)

# The cache's property at two shapes, the XIP slave with Tutorial 22's bus
# checker, and the interconnect with this map. A proof and a cover run for each.
formal: | build
	sby -f --prefix build/formal icache.sby
	@echo "$$(grep -l 'DONE (PASS' build/formal_*/logfile.txt | wc -l) tasks passed"

# The flags leave out I/O and clock buffers so the counts show only the logic.
# The cache alone at three sizes on each family, then the whole system.
synth: build/tight.hex | build
	@for size in 16 64 256; do \
		yosys -q -p "read_verilog rtl/icache.v; chparam -set LINES $$size icache; synth_xilinx -family xc7 -top icache -noiopad -noclkbuf; tee -o build/stat-xilinx-icache-$$size.txt stat" || exit 1; \
		yosys -q -p "read_verilog rtl/icache.v; chparam -set LINES $$size icache; synth_gowin -top icache -noiopads; tee -o build/stat-gowin-icache-$$size.txt stat" || exit 1; \
		yosys -q -p "read_verilog rtl/icache.v; chparam -set LINES $$size icache; synth_intel_alm -family cyclonev -top icache -noiopad -noclkbuf; tee -o build/stat-cyclonev-icache-$$size.txt stat" || exit 1; \
		for family in xilinx gowin cyclonev; do \
			echo "--- icache $$size lines of 4 words, $$family"; sed -n '/cells$$/,$$p' build/stat-$$family-icache-$$size.txt; \
		done; \
	done
	yosys -q -p "read_verilog -Irtl $(RTL); chparam -set INIT \"build/tight.hex\" $(TOP); synth_xilinx -family xc7 -top $(TOP) -noiopad -noclkbuf -flatten; tee -o build/stat-xilinx.txt stat"
	yosys -q -p "read_verilog -Irtl $(RTL); chparam -set INIT \"build/tight.hex\" $(TOP); synth_gowin -top $(TOP) -noiopads; tee -o build/stat-gowin.txt stat"
	yosys -q -p "read_verilog -Irtl $(RTL); chparam -set INIT \"build/tight.hex\" $(TOP); synth_intel_alm -family cyclonev -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-cyclonev.txt stat"
	@for family in xilinx gowin cyclonev; do \
		echo "--- $(TOP) $$family"; sed -n '/cells$$/,$$p' build/stat-$$family.txt; \
	done

# The cache control slave. The cache itself, even at two lines of one word,
# draws as a tangle of hundreds of cells that nobody could read.
schematic: | build
	yosys -q -p "read_verilog rtl/wb_cachectl.v; prep -top wb_cachectl; show -format png -prefix build/wb_cachectl wb_cachectl"

clean:
	rm -rf build tb/__pycache__ tools/__pycache__
