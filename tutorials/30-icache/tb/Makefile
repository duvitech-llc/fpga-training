# Run through "make cocotb" in the parent directory.
SIM ?= icarus
SEED ?= 30
TOPLEVEL_LANG = verilog
RTL_DIR = $(CURDIR)/../rtl
VERILOG_SOURCES = $(CURDIR)/cache_top.v $(CURDIR)/spi_flash_model.v \
	$(RTL_DIR)/soc.v $(RTL_DIR)/rv32i.v $(RTL_DIR)/rv_decode.v $(RTL_DIR)/rv_alu.v \
	$(RTL_DIR)/rv_regs.v $(RTL_DIR)/enreg.v $(RTL_DIR)/icache.v $(RTL_DIR)/rv_wb_bridge.v \
	$(RTL_DIR)/wb_interconnect.v $(RTL_DIR)/wb_ram.v $(RTL_DIR)/wb_gpio.v \
	$(RTL_DIR)/wb_counters.v $(RTL_DIR)/wb_cachectl.v $(RTL_DIR)/wb_xip.v \
	$(RTL_DIR)/spi_master.v $(RTL_DIR)/shift_reg.v
COMPILE_ARGS += -I$(RTL_DIR)
COCOTB_TOPLEVEL = cache_top
COCOTB_TEST_MODULES = test_icache
# A fixed seed, so a run is repeatable and the coverage check always sees the same tests.
export COCOTB_RANDOM_SEED = $(SEED)
SIM_BUILD = $(CURDIR)/../build/cocotb
COCOTB_RESULTS_FILE = $(SIM_BUILD)/results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
