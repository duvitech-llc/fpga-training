# Run through "make cocotb" in the parent directory.
SIM ?= icarus
TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(CURDIR)/../rtl/shift_reg.v $(CURDIR)/../rtl/spi_master.v
COCOTB_TOPLEVEL = spi_master
COCOTB_TEST_MODULES = test_spi
SIM_BUILD = $(CURDIR)/../build/cocotb
COCOTB_RESULTS_FILE = $(SIM_BUILD)/results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
