# Run through "make cocotb" in the parent directory.
SIM ?= icarus
CLKS_PER_BIT ?= 16
TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(CURDIR)/../rtl/computer.v $(CURDIR)/../rtl/bus.v $(CURDIR)/../rtl/cpu.v \
	$(CURDIR)/../rtl/decode.v $(CURDIR)/../rtl/alu_flags.v $(CURDIR)/../rtl/regfile.v \
	$(CURDIR)/../rtl/enreg.v $(CURDIR)/../rtl/uart.v $(CURDIR)/../rtl/uart_tx.v \
	$(CURDIR)/../rtl/uart_rx.v
COMPILE_ARGS += -Pcomputer.CLKS_PER_BIT=$(CLKS_PER_BIT)
COCOTB_TOPLEVEL = computer
COCOTB_TEST_MODULES = test_computer
# One directory per CLKS_PER_BIT, otherwise changing it would not recompile the design.
SIM_BUILD = $(CURDIR)/../build/cocotb-$(CLKS_PER_BIT)
COCOTB_RESULTS_FILE = $(SIM_BUILD)/results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
