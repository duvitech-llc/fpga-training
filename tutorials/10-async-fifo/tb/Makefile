# Run through "make cocotb" in the parent directory.
SIM ?= icarus
WIDTH ?= 8
ADDR_WIDTH ?= 4
TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(CURDIR)/../rtl/async_fifo.v $(CURDIR)/../rtl/gray_ptr.v
COMPILE_ARGS += -Pasync_fifo.WIDTH=$(WIDTH) -Pasync_fifo.ADDR_WIDTH=$(ADDR_WIDTH)
COCOTB_TOPLEVEL = async_fifo
COCOTB_TEST_MODULES = test_async_fifo
# One directory per parameter set, otherwise a change would not recompile the design.
SIM_BUILD = $(CURDIR)/../build/cocotb-$(WIDTH)-$(ADDR_WIDTH)
COCOTB_RESULTS_FILE = $(SIM_BUILD)/results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
