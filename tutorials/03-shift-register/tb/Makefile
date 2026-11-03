# Run through "make cocotb" in the parent directory.
SIM ?= icarus
WIDTH ?= 8
TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(CURDIR)/../rtl/shift_reg.v
COMPILE_ARGS += -Pshift_reg.WIDTH=$(WIDTH)
COCOTB_TOPLEVEL = shift_reg
COCOTB_TEST_MODULES = test_shift_reg
# One directory per WIDTH, otherwise changing WIDTH would not recompile the design.
SIM_BUILD = $(CURDIR)/../build/cocotb-$(WIDTH)
COCOTB_RESULTS_FILE = $(SIM_BUILD)/results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
