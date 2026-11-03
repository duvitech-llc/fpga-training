# Run through "make cocotb" in the parent directory.
SIM ?= icarus
WIDTH ?= 8
DEPTH ?= 16
TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(CURDIR)/../rtl/sync_fifo.v
COMPILE_ARGS += -Psync_fifo.WIDTH=$(WIDTH) -Psync_fifo.DEPTH=$(DEPTH)
COCOTB_TOPLEVEL = sync_fifo
COCOTB_TEST_MODULES = test_sync_fifo
# One directory per size, otherwise changing a parameter would not recompile the design.
SIM_BUILD = $(CURDIR)/../build/cocotb-$(WIDTH)-$(DEPTH)
COCOTB_RESULTS_FILE = $(SIM_BUILD)/results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
