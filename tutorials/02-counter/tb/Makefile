# Run through "make cocotb" in the parent directory.
SIM ?= icarus
MOD ?= 10
TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(CURDIR)/../rtl/counter.v
COMPILE_ARGS += -Pcounter.MOD=$(MOD)
COCOTB_TOPLEVEL = counter
COCOTB_TEST_MODULES = test_counter
# One directory per MOD, otherwise changing MOD would not recompile the design.
SIM_BUILD = $(CURDIR)/../build/cocotb-$(MOD)
COCOTB_RESULTS_FILE = $(SIM_BUILD)/results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
