# Run through "make cocotb" in the parent directory.
SIM ?= icarus
SEED ?= 28
CLKS_PER_BIT ?= 16
TOPLEVEL_LANG = verilog
RTL_DIR = $(CURDIR)/../rtl
VERILOG_SOURCES = $(CURDIR)/boot_top.v $(CURDIR)/spi_flash_model.v \
	$(RTL_DIR)/soc.v $(RTL_DIR)/rv32i.v $(RTL_DIR)/rv_decode.v $(RTL_DIR)/rv_alu.v \
	$(RTL_DIR)/rv_regs.v $(RTL_DIR)/enreg.v $(RTL_DIR)/rv_wb_bridge.v $(RTL_DIR)/wb_interconnect.v \
	$(RTL_DIR)/wb_ram.v $(RTL_DIR)/wb_uart.v $(RTL_DIR)/uart.v $(RTL_DIR)/uart_tx.v \
	$(RTL_DIR)/uart_rx.v $(RTL_DIR)/wb_gpio.v $(RTL_DIR)/wb_counters.v \
	$(RTL_DIR)/wb_axil_bridge.v $(RTL_DIR)/axil_regs.v $(RTL_DIR)/wb_rom.v \
	$(RTL_DIR)/wb_spi.v $(RTL_DIR)/spi_master.v $(RTL_DIR)/shift_reg.v \
	$(RTL_DIR)/wb_crc.v $(RTL_DIR)/crc32_byte.v
COMPILE_ARGS += -I$(RTL_DIR) -Pboot_top.CLKS_PER_BIT=$(CLKS_PER_BIT)
COCOTB_TOPLEVEL = boot_top
COCOTB_TEST_MODULES = test_boot
# A fixed seed, so a run is repeatable.
export COCOTB_RANDOM_SEED = $(SEED)
SIM_BUILD = $(CURDIR)/../build/cocotb
COCOTB_RESULTS_FILE = $(SIM_BUILD)/results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
