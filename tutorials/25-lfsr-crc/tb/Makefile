# Run through "make cocotb" in the parent directory, once for each design.
SIM ?= icarus
DESIGN ?= crc32_byte
TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(CURDIR)/../rtl/$(DESIGN).v
COCOTB_TOPLEVEL = $(DESIGN)
# Both byte CRCs have the same ports, so they share a test.
ifeq ($(DESIGN),crc32_serial)
COCOTB_TEST_MODULES = test_crc32_serial
else
COCOTB_TEST_MODULES = test_crc32_byte
endif
# One directory per design, otherwise changing DESIGN would not recompile it.
SIM_BUILD = $(CURDIR)/../build/cocotb-$(DESIGN)
COCOTB_RESULTS_FILE = $(SIM_BUILD)/results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
