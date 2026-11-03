# Run through "make cocotb" in the parent directory.
SIM ?= icarus
TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(CURDIR)/../rtl/wb_system.v $(CURDIR)/../rtl/wb_master.v \
	$(CURDIR)/../rtl/wb_interconnect.v $(CURDIR)/../rtl/wb_regfile.v
COCOTB_TOPLEVEL = wb_system
COCOTB_TEST_MODULES = test_wishbone
SIM_BUILD = $(CURDIR)/../build/cocotb
COCOTB_RESULTS_FILE = $(SIM_BUILD)/results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
