# Run through "make cocotb" in the parent directory, which sets MODE.
SIM ?= icarus
MODE ?= small
TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(CURDIR)/../rtl/video_timing.v $(CURDIR)/../rtl/test_pattern.v \
                  $(CURDIR)/../rtl/video_top.v
COCOTB_TOPLEVEL = video_top
COCOTB_TEST_MODULES = test_video

# The same small mode as the parent Makefile, with a box to fit it. A VGA frame
# is 420,000 clocks, so the VGA run captures only two.
ifeq ($(MODE),small)
PARAMS := H_ACTIVE=32 H_FRONT=4 H_SYNC=6 H_BACK=6 V_ACTIVE=24 V_FRONT=2 V_SYNC=3 V_BACK=4 \
          H_POL=1 V_POL=1 BOX=4 STEP=3
export FRAMES := 12
else
PARAMS :=
export FRAMES := 2
endif
export MODE

COMPILE_ARGS += $(foreach p,$(PARAMS),-Pvideo_top.$(p))
# One directory per mode, otherwise changing mode would not recompile the design.
SIM_BUILD = $(CURDIR)/../build/cocotb-$(MODE)
COCOTB_RESULTS_FILE = $(SIM_BUILD)/results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
