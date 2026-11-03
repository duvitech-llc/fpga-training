CORE := rtl/rv32i.v rtl/rv_decode.v rtl/rv_alu.v rtl/rv_regs.v rtl/enreg.v
UART := rtl/uart.v rtl/uart_tx.v rtl/uart_rx.v
SPI  := rtl/wb_spi.v rtl/spi_master.v rtl/shift_reg.v
CRC  := rtl/wb_crc.v rtl/crc32_byte.v
RTL  := rtl/soc.v $(CORE) rtl/rv_wb_bridge.v rtl/wb_interconnect.v rtl/wb_ram.v \
	rtl/wb_uart.v $(UART) rtl/wb_gpio.v rtl/wb_counters.v rtl/wb_axil_bridge.v rtl/axil_regs.v \
	rtl/wb_rom.v $(SPI) $(CRC)
TB   := tb/tb_boot.v tb/spi_flash_model.v
TOP  := soc
SEED ?= 28
CLKS_PER_BIT ?= 16

# The SPI dividers the boot ROMs are built for. Divider 0 is too fast for the
# flash model's read command, see the README.
DIVS := 1 3 7 15
ROMS := $(foreach d,$(DIVS),build/rom_stream_d$(d).hex build/rom_poll_d$(d).hex)
PAYLOADS := $(patsubst programs/%.asm,build/%.hex,$(wildcard programs/*.asm))
FLASH := build/flash_hello.hex build/flash_bitflip.hex build/flash_magic.hex \
	build/flash_length.hex build/flash_again.hex build/flash_romwrite.hex build/flash_big.hex

.PHONY: all images sim lint verilator cocotb formal synth schematic clean

all: images sim lint verilator cocotb formal synth schematic

build:
	mkdir -p build

# ----- The boot ROMs, the payloads and the flash images -----

# A boot ROM is three pieces: the divider, rom/boot.asm, and one way to read a
# byte. Tutorial 21's assembler, then padded to the ROM's 256 words.
build/rom_stream_d%.hex: rom/boot.asm rom/getbyte_stream.asm tools/asm.py tools/pad_hex.py | build
	printf '        .equ   SPI_DIV, %s\n' $* | cat - rom/boot.asm rom/getbyte_stream.asm > build/rom_stream_d$*.asm
	python3 tools/asm.py build/rom_stream_d$*.asm $@.raw --list > build/rom_stream_d$*.lst
	python3 tools/pad_hex.py $@.raw $@ 256

build/rom_poll_d%.hex: rom/boot.asm rom/getbyte_poll.asm tools/asm.py tools/pad_hex.py | build
	printf '        .equ   SPI_DIV, %s\n' $* | cat - rom/boot.asm rom/getbyte_poll.asm > build/rom_poll_d$*.asm
	python3 tools/asm.py build/rom_poll_d$*.asm $@.raw --list > build/rom_poll_d$*.lst
	python3 tools/pad_hex.py $@.raw $@ 256

# A payload, as asm.py writes it: no padding, since mkflash.py takes its length.
build/%.hex: programs/%.asm tools/asm.py | build
	python3 tools/asm.py $< $@

build/flash_hello.hex: build/hello.hex tools/mkflash.py
	python3 tools/mkflash.py $< $@
build/flash_bitflip.hex: build/hello.hex tools/mkflash.py
	python3 tools/mkflash.py $< $@ --flip-bit 5:3
build/flash_magic.hex: build/hello.hex tools/mkflash.py
	python3 tools/mkflash.py $< $@ --magic 0x544F4F43
build/flash_length.hex: build/hello.hex tools/mkflash.py
	python3 tools/mkflash.py $< $@ --length 0x10000
build/flash_again.hex: build/again.hex tools/mkflash.py
	python3 tools/mkflash.py $< $@
build/flash_romwrite.hex: build/romwrite.hex tools/mkflash.py
	python3 tools/mkflash.py $< $@
build/flash_big.hex: build/hello.hex tools/mkflash.py
	python3 tools/mkflash.py $< $@ --pad-to 1024

images: $(ROMS) $(PAYLOADS) $(FLASH)

# ----- Checks -----

sim: images
	iverilog -g2012 -Irtl -Ptb_boot.CLKS_PER_BIT=$(CLKS_PER_BIT) -o build/tb_boot.vvp $(TB) $(RTL)
	vvp -n build/tb_boot.vvp +waves

# The whole system, then each new module on its own.
lint:
	verilator --lint-only -Wall -Irtl -GCLKS_PER_BIT=$(CLKS_PER_BIT) --top-module $(TOP) $(RTL)
	verilator --lint-only -Wall --top-module wb_rom rtl/wb_rom.v
	verilator --lint-only -Wall --top-module wb_spi $(SPI)
	verilator --lint-only -Wall --top-module wb_crc $(CRC)

verilator: images
	verilator --binary --timing --trace -Irtl -GCLKS_PER_BIT=$(CLKS_PER_BIT) --Mdir build/obj_boot \
		--top-module tb_boot $(TB) $(RTL) > build/verilator_boot.log
	build/obj_boot/Vtb_boot

cocotb: images
	$(MAKE) -C tb SEED=$(SEED) CLKS_PER_BIT=$(CLKS_PER_BIT)

# The three new slaves, each with Tutorial 22's bus checker, and the
# interconnect with the new map. A proof and a cover run for each.
formal: | build
	sby -f --prefix build/formal boot.sby
	@echo "$$(grep -l 'DONE (PASS' build/formal_*/logfile.txt | wc -l) tasks passed"

# The flags leave out I/O and clock buffers so the counts show only the logic.
# The new slaves alone first, then the whole system with the streaming boot ROM.
synth: build/rom_stream_d1.hex | build
	@for top in wb_rom wb_spi wb_crc; do \
		yosys -q -p "read_verilog rtl/wb_rom.v $(SPI) $(CRC); synth_xilinx -family xc7 -top $$top -noiopad -noclkbuf -flatten; tee -o build/stat-xilinx-$$top.txt stat" || exit 1; \
		echo "--- $$top xilinx"; sed -n '/cells$$/,$$p' build/stat-xilinx-$$top.txt; \
	done
	yosys -q -p "read_verilog -Irtl $(RTL); chparam -set ROM_INIT \"build/rom_stream_d1.hex\" -set CLKS_PER_BIT $(CLKS_PER_BIT) $(TOP); synth_xilinx -family xc7 -top $(TOP) -noiopad -noclkbuf -flatten; tee -o build/stat-xilinx.txt stat"
	yosys -q -p "read_verilog -Irtl $(RTL); chparam -set ROM_INIT \"build/rom_stream_d1.hex\" -set CLKS_PER_BIT $(CLKS_PER_BIT) $(TOP); synth_gowin -top $(TOP) -noiopads; tee -o build/stat-gowin.txt stat"
	yosys -q -p "read_verilog -Irtl $(RTL); chparam -set ROM_INIT \"build/rom_stream_d1.hex\" -set CLKS_PER_BIT $(CLKS_PER_BIT) $(TOP); synth_intel_alm -family cyclonev -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-cyclonev.txt stat"
	@for family in xilinx gowin cyclonev; do \
		echo "--- $(TOP) $$family"; sed -n '/cells$$/,$$p' build/stat-$$family.txt; \
	done

# The CRC slave, with crc32_byte as one box. The whole system would be unreadable.
schematic: | build
	yosys -q -p "read_verilog $(CRC); prep -top wb_crc; show -format png -prefix build/wb_crc wb_crc"

clean:
	rm -rf build tb/__pycache__ tools/__pycache__
