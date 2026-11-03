CORE := rtl/rv32i.v rtl/rv_decode.v rtl/rv_alu.v rtl/rv_regs.v rtl/enreg.v rtl/rv_csr.v
UART := rtl/uart.v rtl/uart_tx.v rtl/uart_rx.v
SPI  := rtl/wb_spi.v rtl/spi_master.v rtl/shift_reg.v
CRC  := rtl/wb_crc.v rtl/crc32_byte.v
ARB  := rtl/wb_arbiter.v rtl/rr_arbiter.v rtl/fixed_arbiter.v
# Tutorial 33's video: the display controller and the DVI transmitter.
DISPLAY := rtl/display.v rtl/wb_display.v rtl/display_pixel.v rtl/video_timing.v \
	rtl/async_fifo.v rtl/gray_ptr.v rtl/sync_2ff.v rtl/reset_sync.v
DVI  := rtl/dvi_tx.v rtl/tmds_encoder.v rtl/tmds_serialiser.v
RTL  := rtl/soc.v $(CORE) rtl/icache.v rtl/rv_wb_bridge.v $(ARB) rtl/wb_interconnect.v \
	rtl/wb_ram.v rtl/wb_uart.v $(UART) rtl/wb_gpio.v rtl/wb_counters.v rtl/wb_axil_bridge.v \
	rtl/axil_regs.v rtl/wb_timer.v rtl/wb_rom.v $(SPI) $(CRC) rtl/wb_dma.v rtl/wb_cachectl.v \
	rtl/wb_xip.v rtl/wb_gate.v rtl/flash_share.v rtl/wb_intc.v $(DISPLAY) $(DVI)
TB   := tb/tb_dvi.v tb/spi_flash_model.v
TOP  := soc
CLKS_PER_BIT ?= 16

# The four runs of make sim and make verilator, as plusargs for tb/tb_dvi.v:
#   nominal   no stalls, a 39 ns pixel clock; writes build/live.png too
#   stalls    every slave stalls at random, about one clock in four
#   fast      stalls, and a 14 ns pixel clock: the FIFO drains 2.8 times as fast
#   underrun  the framebuffer stalls for 3000 clocks in one frame, on purpose
RUNS         := nominal stalls fast underrun
RUN_nominal  := +mode=0 +frames=6 +keep=6 +live=build/live.png
RUN_stalls   := +mode=1 +frames=6 +keep=6
RUN_fast     := +mode=1 +frames=9 +keep=0 +pix_ps=14000
RUN_underrun := +mode=2 +frames=6 +keep=6
# The frames of these runs are compared with the Python model of the picture.
CHECKED      := nominal stalls

# make live: how many frames the Verilator model draws, and the file it writes
# each frame to. That file is outside build/ on purpose: VS Code's preview did
# not reload a file under /work, the folder shared with the host, when it
# changed (seen on Windows with Docker Desktop). In the container's own /tmp it
# did. So run make live in VS Code's terminal, where /tmp is the IDE's.
LIVE_FRAMES ?= 600
LIVE_PNG    ?= /tmp/live.png

# The C compiler and its flags, as in Tutorial 31, with build/ for font.h.
CC      := riscv-none-elf-gcc
OBJCOPY := riscv-none-elf-objcopy
OBJDUMP := riscv-none-elf-objdump
CFLAGS  := -march=rv32i_zicsr -mabi=ilp32 -O2 -ffreestanding -nostdlib -Wall -Wextra -Werror \
	-Isw -Ibuild
LDFLAGS := -T sw/link.ld -ffunction-sections -fdata-sections -Wl,--gc-sections \
	-Wl,--no-warn-rwx-segments
SW      := sw/crt0.S sw/lib.c

VERILATOR_FLAGS := --binary --timing --no-sched-zero-delay -Irtl \
	-GCLKS_PER_BIT=$(CLKS_PER_BIT) --Mdir build/obj_dvi --top-module tb_dvi

.PHONY: all images sim lint verilator live cocotb formal synth schematic clean
# sim-% and verilator-% below are pattern rules. make skips pattern rules for
# .PHONY targets, so they are not listed; no files of those names exist.

all: images sim lint verilator cocotb formal synth schematic

build:
	mkdir -p build

# ----- The boot ROM: Tutorial 31's, unchanged -----

build/boot.hex: rom/boot.asm rom/getbyte_stream.asm tools/asm.py tools/pad_hex.py | build
	printf '        .equ   SPI_DIV, 1\n' | cat - rom/boot.asm rom/getbyte_stream.asm > build/boot.asm
	python3 tools/asm.py build/boot.asm build/boot.raw --list > build/boot.lst
	python3 tools/pad_hex.py build/boot.raw $@ 256

# ----- The program, in C -----

build/font.h: tools/font.py | build
	python3 tools/font.py $@

build/draw.elf: programs/draw.c $(SW) sw/soc.h sw/link.ld build/font.h | build
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SW) programs/draw.c -lgcc

build/draw.ram.bin: build/draw.elf
	$(OBJCOPY) -O binary -R .xip $< $@

build/draw.dis: build/draw.elf
	$(OBJDUMP) -d $< > $@

build/flash_draw.hex: build/draw.ram.bin tools/mkflash.py
	python3 tools/mkflash.py --load 0 --entry 0 build/draw.ram.bin $@

images: build/boot.hex build/flash_draw.hex build/draw.dis

# ----- Simulation -----

# The four runs go in parallel, each into its own log; --output-sync prints
# each run's lines together. A run passes if its last line is PASS, and the
# checked runs' frames must also match tools/scene.py.
sim: images
	iverilog -g2012 -Irtl -Ptb_dvi.CLKS_PER_BIT=$(CLKS_PER_BIT) -o build/tb_dvi.vvp $(TB) $(RTL)
	$(MAKE) --no-print-directory -j4 --output-sync=target $(addprefix sim-,$(RUNS))

sim-%:
	mkdir -p build/sim_$*
	vvp -n build/tb_dvi.vvp $(RUN_$*) +out=build/sim_$* $(if $(filter nominal,$*),+waves) \
		> build/sim_$*.log 2>&1; tail -n 16 build/sim_$*.log
	grep -q '^PASS$$' build/sim_$*.log
	$(if $(filter $*,$(CHECKED)),python3 tb/check_frames.py build/sim_$* \
		$(if $(filter nominal,$*),build/live.png))

# The same testbench, unchanged. Built without --trace, and not given +waves.
verilator: images
	verilator $(VERILATOR_FLAGS) $(TB) $(RTL) > build/verilator_dvi.log
	$(MAKE) --no-print-directory -j4 --output-sync=target $(addprefix verilator-,$(RUNS))

verilator-%:
	mkdir -p build/verilator_$*
	build/obj_dvi/Vtb_dvi $(RUN_$*) +out=build/verilator_$* > build/verilator_$*.log 2>&1; \
		tail -n 16 build/verilator_$*.log
	grep -q '^PASS$$' build/verilator_$*.log
	$(if $(filter $*,$(CHECKED)),python3 tb/check_frames.py build/verilator_$* \
		$(if $(filter nominal,$*),build/live.png))

# The live view: the Verilator model draws LIVE_FRAMES frames, writing each to
# LIVE_PNG. Open that file in VS Code while this runs.
live: images
	verilator $(VERILATOR_FLAGS) $(TB) $(RTL) > build/verilator_dvi.log
	mkdir -p build/live
	build/obj_dvi/Vtb_dvi +mode=0 +frames=$(LIVE_FRAMES) +keep=10 +out=build/live \
		+live=$(LIVE_PNG)

# ----- The other checks -----

# The whole system, then each new or changed module on its own.
lint:
	verilator --lint-only -Wall -Irtl -GCLKS_PER_BIT=$(CLKS_PER_BIT) --top-module $(TOP) $(RTL)
	verilator --lint-only -Wall --top-module tmds_encoder rtl/tmds_encoder.v
	verilator --lint-only -Wall --top-module dvi_tx $(DVI)
	verilator --lint-only -Wall --top-module display $(DISPLAY)
	verilator --lint-only -Wall --top-module async_fifo rtl/async_fifo.v rtl/gray_ptr.v
	verilator --lint-only -Wall --top-module wb_intc rtl/wb_intc.v

cocotb:
	$(MAKE) -C tb TEST=tmds
	$(MAKE) -C tb TEST=display

formal: | build
	sby -f --prefix build/formal dvi.sby
	@echo "$$(grep -l 'DONE (PASS' build/formal_*/logfile.txt | wc -l) tasks passed"

# The flags leave out I/O and clock buffers so the counts show only the logic.
# The new parts alone first, then the whole system with the boot ROM in it.
synth: build/boot.hex | build
	yosys -q -p "read_verilog rtl/tmds_encoder.v; synth_xilinx -family xc7 -top tmds_encoder -noiopad -noclkbuf -flatten; tee -o build/stat-xilinx-tmds_encoder.txt stat"
	yosys -q -p "read_verilog $(DISPLAY); synth_xilinx -family xc7 -top display -noiopad -noclkbuf -flatten; tee -o build/stat-xilinx-display.txt stat"
	@for top in tmds_encoder display; do \
		echo "--- $$top xilinx"; sed -n '/cells$$/,$$p' build/stat-xilinx-$$top.txt; \
	done
	yosys -q -p "read_verilog -Irtl $(RTL); chparam -set ROM_INIT \"build/boot.hex\" -set CLKS_PER_BIT $(CLKS_PER_BIT) $(TOP); synth_xilinx -family xc7 -top $(TOP) -noiopad -noclkbuf -flatten; tee -o build/stat-xilinx.txt stat"
	yosys -q -p "read_verilog -Irtl $(RTL); chparam -set ROM_INIT \"build/boot.hex\" -set CLKS_PER_BIT $(CLKS_PER_BIT) $(TOP); synth_gowin -top $(TOP) -noiopads; tee -o build/stat-gowin.txt stat"
	yosys -q -p "read_verilog -Irtl $(RTL); chparam -set ROM_INIT \"build/boot.hex\" -set CLKS_PER_BIT $(CLKS_PER_BIT) $(TOP); synth_intel_alm -family cyclonev -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-cyclonev.txt stat"
	@for family in xilinx gowin cyclonev; do \
		echo "--- $(TOP) $$family"; sed -n '/cells$$/,$$p' build/stat-$$family.txt; \
	done

# The serialiser: the encoder's population counts would be unreadable.
schematic: | build
	yosys -q -p "read_verilog rtl/tmds_serialiser.v; prep -top tmds_serialiser; show -format png -prefix build/tmds_serialiser tmds_serialiser"

clean:
	rm -rf build tb/__pycache__ tools/__pycache__
