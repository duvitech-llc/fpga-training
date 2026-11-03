# Run through "make cocotb" in the parent directory.
SIM ?= icarus
WIDTH ?= 8
TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(CURDIR)/../rtl/skid_buffer.v
COMPILE_ARGS += -Pskid_buffer.WIDTH=$(WIDTH)
COCOTB_TOPLEVEL = skid_buffer
COCOTB_TEST_MODULES = test_skid_buffer
# One directory per WIDTH, otherwise changing WIDTH would not recompile the design.
SIM_BUILD = $(CURDIR)/../build/cocotb-$(WIDTH)
COCOTB_RESULTS_FILE = $(SIM_BUILD)/results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
