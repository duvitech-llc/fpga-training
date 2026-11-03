CORE := rtl/rv32i.v rtl/rv_decode.v rtl/rv_alu.v rtl/rv_regs.v rtl/enreg.v rtl/rv_csr.v
UART := rtl/uart.v rtl/uart_tx.v rtl/uart_rx.v
SPI  := rtl/wb_spi.v rtl/spi_master.v rtl/shift_reg.v
CRC  := rtl/wb_crc.v rtl/crc32_byte.v
ARB  := rtl/wb_arbiter.v rtl/rr_arbiter.v rtl/fixed_arbiter.v
RTL  := rtl/soc.v $(CORE) rtl/icache.v rtl/rv_wb_bridge.v $(ARB) rtl/wb_interconnect.v \
	rtl/wb_ram.v rtl/wb_uart.v $(UART) rtl/wb_gpio.v rtl/wb_counters.v rtl/wb_axil_bridge.v \
	rtl/axil_regs.v rtl/wb_timer.v rtl/wb_rom.v $(SPI) $(CRC) rtl/wb_dma.v rtl/wb_cachectl.v \
	rtl/wb_xip.v rtl/wb_gate.v rtl/flash_share.v rtl/wb_intc.v
TB   := tb/tb_soc.v tb/spi_flash_model.v
TOP  := soc
SEED ?= 31
CLKS_PER_BIT ?= 16

PROGRAMS := demo irqmix irqload reboot second
ELF  := $(patsubst %,build/%.elf,$(PROGRAMS))
EXIT := $(patsubst %,build/%.exit,$(PROGRAMS))
DIS  := $(patsubst %,build/%.dis,$(PROGRAMS))
FLASH := build/flash_demo.hex build/flash_irqmix.hex build/flash_irqload.hex build/flash_reboot.hex \
	build/flash_badcrc.hex
.SECONDARY: $(ELF) $(patsubst %,build/%.ram.bin,$(PROGRAMS)) $(patsubst %,build/%.xip.bin,$(PROGRAMS))

# The C compiler and its flags, as in Tutorial 27.
CC      := riscv-none-elf-gcc
OBJCOPY := riscv-none-elf-objcopy
OBJDUMP := riscv-none-elf-objdump
NM      := riscv-none-elf-nm
CFLAGS  := -march=rv32i_zicsr -mabi=ilp32 -O2 -ffreestanding -nostdlib -Wall -Wextra -Werror \
	-Isw
LDFLAGS := -T sw/link.ld -ffunction-sections -fdata-sections -Wl,--gc-sections \
	-Wl,--no-warn-rwx-segments
SW      := sw/crt0.S sw/lib.c

.PHONY: all images sim lint verilator cocotb formal synth schematic clean

all: images sim lint verilator cocotb formal synth schematic

build:
	mkdir -p build

# ----- The boot ROM: Tutorial 28's, streaming, at SPI divider 1 -----

build/boot.hex: rom/boot.asm rom/getbyte_stream.asm tools/asm.py tools/pad_hex.py | build
	printf '        .equ   SPI_DIV, 1\n' | cat - rom/boot.asm rom/getbyte_stream.asm > build/boot.asm
	python3 tools/asm.py build/boot.asm build/boot.raw --list > build/boot.lst
	python3 tools/pad_hex.py build/boot.raw $@ 256

# ----- The programs, in C -----

# The ELF, then two binaries: everything for RAM, which goes in the boot image,
# and .xip, which goes in the flash as it is. .exit is _exit's address and .dis
# the disassembly, as in Tutorial 27.
build/%.elf: programs/%.c $(SW) sw/soc.h sw/link.ld | build
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SW) $< -lgcc

build/%.ram.bin: build/%.elf
	$(OBJCOPY) -O binary -R .xip $< $@

build/%.xip.bin: build/%.elf
	$(OBJCOPY) -O binary -j .xip $< $@

build/%.exit: build/%.elf
	$(NM) $< | awk '$$3 == "_exit" { print $$1 }' > $@

build/%.dis: build/%.elf
	$(OBJDUMP) -d $< > $@

# ----- The flash images -----

MKFLASH := python3 tools/mkflash.py --load 0 --entry 0

build/flash_demo.hex: build/demo.ram.bin build/demo.xip.bin tools/mkflash.py
	$(MKFLASH) build/demo.ram.bin $@ --raw build/demo.xip.bin@0x8000
build/flash_badcrc.hex: build/demo.ram.bin build/demo.xip.bin tools/mkflash.py
	$(MKFLASH) build/demo.ram.bin $@ --raw build/demo.xip.bin@0x8000 --flip-bit 100:2
build/flash_irqmix.hex: build/irqmix.ram.bin tools/mkflash.py
	$(MKFLASH) build/irqmix.ram.bin $@
build/flash_irqload.hex: build/irqload.ram.bin tools/mkflash.py
	$(MKFLASH) build/irqload.ram.bin $@
build/flash_reboot.hex: build/reboot.ram.bin build/second.ram.bin tools/mkflash.py
	$(MKFLASH) build/reboot.ram.bin $@ --image build/second.ram.bin@0xC000

images: build/boot.hex $(FLASH) $(EXIT) $(DIS)

# ----- Checks -----

sim: images
	iverilog -g2012 -Irtl -Ptb_soc.CLKS_PER_BIT=$(CLKS_PER_BIT) -o build/tb_soc.vvp $(TB) $(RTL)
	vvp -n build/tb_soc.vvp +waves

# The whole system, then each new or changed module on its own.
lint:
	verilator --lint-only -Wall -Irtl -GCLKS_PER_BIT=$(CLKS_PER_BIT) --top-module $(TOP) $(RTL)
	verilator --lint-only -Wall --top-module wb_intc rtl/wb_intc.v
	verilator --lint-only -Wall --top-module flash_share rtl/flash_share.v
	verilator --lint-only -Wall --top-module wb_gate rtl/wb_gate.v
	verilator --lint-only -Wall --top-module wb_uart rtl/wb_uart.v $(UART)
	verilator --lint-only -Wall --top-module wb_spi $(SPI)

# Built without --trace: Verilator ignores $dumpoff, and the testbench records
# only with +waves, which this run does not pass.
verilator: images
	verilator --binary --timing -Irtl -GCLKS_PER_BIT=$(CLKS_PER_BIT) --Mdir build/obj_soc \
		--top-module tb_soc $(TB) $(RTL) > build/verilator_soc.log
	build/obj_soc/Vtb_soc

cocotb: images
	$(MAKE) -C tb SEED=$(SEED) CLKS_PER_BIT=$(CLKS_PER_BIT)

formal: | build
	sby -f --prefix build/formal soc.sby
	@echo "$$(grep -l 'DONE (PASS' build/formal_*/logfile.txt | wc -l) tasks passed"

# The flags leave out I/O and clock buffers so the counts show only the logic.
# The new modules alone first, then the whole system with the boot ROM in it.
# The RAM starts empty: the boot ROM fills it.
synth: build/boot.hex | build
	@for top in wb_intc flash_share; do \
		yosys -q -p "read_verilog rtl/$$top.v; synth_xilinx -family xc7 -top $$top -noiopad -noclkbuf -flatten; tee -o build/stat-xilinx-$$top.txt stat" || exit 1; \
		echo "--- $$top xilinx"; sed -n '/cells$$/,$$p' build/stat-xilinx-$$top.txt; \
	done
	yosys -q -p "read_verilog -Irtl $(RTL); chparam -set ROM_INIT \"build/boot.hex\" -set CLKS_PER_BIT $(CLKS_PER_BIT) $(TOP); synth_xilinx -family xc7 -top $(TOP) -noiopad -noclkbuf -flatten; tee -o build/stat-xilinx.txt stat"
	yosys -q -p "read_verilog -Irtl $(RTL); chparam -set ROM_INIT \"build/boot.hex\" -set CLKS_PER_BIT $(CLKS_PER_BIT) $(TOP); synth_gowin -top $(TOP) -noiopads; tee -o build/stat-gowin.txt stat"
	yosys -q -p "read_verilog -Irtl $(RTL); chparam -set ROM_INIT \"build/boot.hex\" -set CLKS_PER_BIT $(CLKS_PER_BIT) $(TOP); synth_intel_alm -family cyclonev -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-cyclonev.txt stat"
	@for family in xilinx gowin cyclonev; do \
		echo "--- $(TOP) $$family"; sed -n '/cells$$/,$$p' build/stat-$$family.txt; \
	done

# The interrupt controller. The system would be unreadable.
schematic: | build
	yosys -q -p "read_verilog rtl/wb_intc.v; prep -top wb_intc; show -format png -prefix build/wb_intc wb_intc"

clean:
	rm -rf build tb/__pycache__ tools/__pycache__
