# Run through "make cocotb" in the parent directory.
SIM ?= icarus
SEED ?= 27
CLKS_PER_BIT ?= 16
export CLKS_PER_BIT
TOPLEVEL_LANG = verilog
RTL_DIR = $(CURDIR)/../rtl
VERILOG_SOURCES = $(RTL_DIR)/soc.v $(RTL_DIR)/rv32i.v $(RTL_DIR)/rv_decode.v $(RTL_DIR)/rv_alu.v \
	$(RTL_DIR)/rv_regs.v $(RTL_DIR)/enreg.v $(RTL_DIR)/rv_csr.v $(RTL_DIR)/rv_wb_bridge.v \
	$(RTL_DIR)/wb_interconnect.v $(RTL_DIR)/wb_ram.v $(RTL_DIR)/wb_uart.v $(RTL_DIR)/uart.v \
	$(RTL_DIR)/uart_tx.v $(RTL_DIR)/uart_rx.v $(RTL_DIR)/wb_gpio.v $(RTL_DIR)/wb_counters.v \
	$(RTL_DIR)/wb_timer.v $(RTL_DIR)/wb_axil_bridge.v $(RTL_DIR)/axil_regs.v
COMPILE_ARGS += -I$(RTL_DIR) -Psoc.CLKS_PER_BIT=$(CLKS_PER_BIT)
COCOTB_TOPLEVEL = soc
COCOTB_TEST_MODULES = test_soc
# A fixed seed, so a run is repeatable and the coverage check always sees the same tests.
export COCOTB_RANDOM_SEED = $(SEED)
SIM_BUILD = $(CURDIR)/../build/cocotb
COCOTB_RESULTS_FILE = $(SIM_BUILD)/results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
