# Run through "make cocotb" in the parent directory.
SIM ?= icarus
WIDTH ?= 8
DEPTH ?= 256
TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(CURDIR)/../rtl/sync_ram.v
COMPILE_ARGS += -Psync_ram.WIDTH=$(WIDTH) -Psync_ram.DEPTH=$(DEPTH)
COCOTB_TOPLEVEL = sync_ram
COCOTB_TEST_MODULES = test_sync_ram
# One directory per size, otherwise changing a size would not recompile the design.
SIM_BUILD = $(CURDIR)/../build/cocotb-$(WIDTH)-$(DEPTH)
COCOTB_RESULTS_FILE = $(SIM_BUILD)/results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
