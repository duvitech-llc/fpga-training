# Run through "make cocotb" in the parent directory.
SIM ?= icarus
TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(CURDIR)/cdc_top.v $(CURDIR)/../rtl/sync_2ff.v \
                  $(CURDIR)/../rtl/pulse_sync.v $(CURDIR)/../rtl/reset_sync.v
COCOTB_TOPLEVEL = cdc_top
COCOTB_TEST_MODULES = test_cdc
SIM_BUILD = $(CURDIR)/../build/cocotb
COCOTB_RESULTS_FILE = $(SIM_BUILD)/results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
