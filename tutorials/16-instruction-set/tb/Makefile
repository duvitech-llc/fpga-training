# Run through "make cocotb" in the parent directory.
SIM ?= icarus
TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(CURDIR)/../rtl/decode.v
COCOTB_TOPLEVEL = decode
COCOTB_TEST_MODULES = test_decode
SIM_BUILD = $(CURDIR)/../build/cocotb
COCOTB_RESULTS_FILE = $(SIM_BUILD)/results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
