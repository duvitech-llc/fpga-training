# Run through "make cocotb" in the parent directory.
SIM ?= icarus
SEED ?= 31
CLKS_PER_BIT ?= 16
export CLKS_PER_BIT
TOPLEVEL_LANG = verilog
RTL_DIR = $(CURDIR)/../rtl
RTL_FILES = soc.v rv32i.v rv_decode.v rv_alu.v rv_regs.v enreg.v rv_csr.v icache.v \
	rv_wb_bridge.v wb_arbiter.v rr_arbiter.v fixed_arbiter.v wb_interconnect.v wb_ram.v \
	wb_uart.v uart.v uart_tx.v uart_rx.v wb_gpio.v wb_counters.v wb_axil_bridge.v \
	axil_regs.v wb_timer.v wb_rom.v wb_spi.v spi_master.v shift_reg.v wb_crc.v crc32_byte.v \
	wb_dma.v wb_cachectl.v wb_xip.v wb_gate.v flash_share.v wb_intc.v
VERILOG_SOURCES = $(CURDIR)/soc_top.v $(CURDIR)/spi_flash_model.v \
	$(addprefix $(RTL_DIR)/,$(RTL_FILES))
COMPILE_ARGS += -I$(RTL_DIR) -Psoc_top.CLKS_PER_BIT=$(CLKS_PER_BIT)
COCOTB_TOPLEVEL = soc_top
COCOTB_TEST_MODULES = test_soc
# A fixed seed, so a run is repeatable and the coverage check always sees the same tests.
export COCOTB_RANDOM_SEED = $(SEED)
SIM_BUILD = $(CURDIR)/../build/cocotb
COCOTB_RESULTS_FILE = $(SIM_BUILD)/results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
