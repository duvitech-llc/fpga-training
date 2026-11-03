# Run through "make cocotb" in the parent directory.
SIM ?= icarus
BUFFERED ?= 1
TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(CURDIR)/../rtl/axil_regs.v
COMPILE_ARGS += -Paxil_regs.BUFFERED=$(BUFFERED)
COCOTB_TOPLEVEL = axil_regs
COCOTB_TEST_MODULES = test_axil_regs
# One directory per slave, otherwise changing BUFFERED would not recompile the design.
SIM_BUILD = $(CURDIR)/../build/cocotb-$(BUFFERED)
COCOTB_RESULTS_FILE = $(SIM_BUILD)/results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
