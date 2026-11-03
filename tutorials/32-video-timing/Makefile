RTL := rtl/video_timing.v rtl/test_pattern.v rtl/video_top.v
TB  := tb/tb_video_timing.v
TOP := video_top

# VGA 640x480 at 60 Hz is the default in the RTL. The small mode is a made-up
# one, with active-high syncs, so the parameters are tested and long runs are quick.
VGA   :=
SMALL := H_ACTIVE=32 H_FRONT=4 H_SYNC=6 H_BACK=6 V_ACTIVE=24 V_FRONT=2 V_SYNC=3 V_BACK=4 \
         H_POL=1 V_POL=1

.PHONY: all sim lint verilator cocotb formal synth schematic clean

all: sim lint verilator cocotb formal synth schematic

build:
	mkdir -p build

# $(1) is the mode's name, $(2) its parameters, $(3) how many frames to run.
define iverilog_run
	iverilog -g2012 $(foreach p,$(2) FRAMES=$(3),-Ptb_video_timing.$(p)) \
		-o build/tb_$(1).vvp $(TB) $(RTL)
	vvp build/tb_$(1).vvp
endef

define verilator_run
	verilator --binary --timing --trace $(addprefix -G,$(2) FRAMES=$(3)) \
		--Mdir build/obj_$(1) --top-module tb_video_timing $(TB) $(RTL)
	build/obj_$(1)/Vtb_video_timing
endef

sim: | build
	$(call iverilog_run,small,$(SMALL),6)
	$(call iverilog_run,vga,$(VGA),2)

lint:
	verilator --lint-only -Wall --top-module $(TOP) $(RTL)
	verilator --lint-only -Wall --top-module $(TOP) $(addprefix -G,$(SMALL)) $(RTL)

verilator: | build
	$(call verilator_run,small,$(SMALL),6)
	$(call verilator_run,vga,$(VGA),2)

cocotb: | build
	$(MAKE) -C tb MODE=small
	$(MAKE) -C tb MODE=vga

formal: | build
	sby -f --prefix build/formal video_timing.sby

# The flags leave out I/O and clock buffers so the counts show only the logic.
synth: | build
	yosys -q -p "read_verilog $(RTL); synth_xilinx -family xc7 -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-xilinx.txt stat"
	yosys -q -p "read_verilog $(RTL); synth_gowin -top $(TOP) -noiopads; tee -o build/stat-gowin.txt stat"
	yosys -q -p "read_verilog $(RTL); synth_intel_alm -family cyclonev -top $(TOP) -noiopad -noclkbuf; tee -o build/stat-cyclonev.txt stat"
	@for family in xilinx gowin cyclonev; do \
		echo "--- $$family"; sed -n '/cells$$/,$$p' build/stat-$$family.txt; \
	done

schematic: | build
	yosys -q -p "read_verilog rtl/video_timing.v; chparam $(foreach p,$(SMALL),-set $(subst =, ,$(p))) video_timing; prep -top video_timing; show -format png -prefix build/video_timing"

clean:
	rm -rf build tb/__pycache__
