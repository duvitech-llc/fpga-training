# Run through "make cocotb" in the parent directory.
SIM ?= icarus
CLKS_PER_BIT ?= 16
TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(CURDIR)/../rtl/uart_tx.v $(CURDIR)/../rtl/uart_rx.v $(CURDIR)/../rtl/uart.v
COMPILE_ARGS += -Puart.CLKS_PER_BIT=$(CLKS_PER_BIT)
COCOTB_TOPLEVEL = uart
COCOTB_TEST_MODULES = test_uart
# One directory per CLKS_PER_BIT, otherwise changing it would not recompile the design.
SIM_BUILD = $(CURDIR)/../build/cocotb-$(CLKS_PER_BIT)
COCOTB_RESULTS_FILE = $(SIM_BUILD)/results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
