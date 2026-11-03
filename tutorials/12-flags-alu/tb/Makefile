# Run through "make cocotb" in the parent directory.
SIM ?= icarus
WIDTH ?= 8
TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(CURDIR)/../rtl/alu_flags.v
COMPILE_ARGS += -Palu_flags.WIDTH=$(WIDTH)
COCOTB_TOPLEVEL = alu_flags
COCOTB_TEST_MODULES = test_alu_flags
# One directory per WIDTH, otherwise changing WIDTH would not recompile the design.
SIM_BUILD = $(CURDIR)/../build/cocotb-$(WIDTH)
COCOTB_RESULTS_FILE = $(SIM_BUILD)/results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
