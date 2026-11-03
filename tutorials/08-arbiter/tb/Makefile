# Run through "make cocotb" in the parent directory.
SIM ?= icarus
N ?= 4
TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(CURDIR)/../rtl/fixed_arbiter.v $(CURDIR)/../rtl/rr_arbiter.v
COMPILE_ARGS += -Prr_arbiter.N=$(N)
COCOTB_TOPLEVEL = rr_arbiter
COCOTB_TEST_MODULES = test_rr_arbiter
# One directory per N, otherwise changing N would not recompile the design.
SIM_BUILD = $(CURDIR)/../build/cocotb-$(N)
COCOTB_RESULTS_FILE = $(SIM_BUILD)/results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
