# Run through "make cocotb" in the parent directory.
SIM ?= icarus
SEED ?= 21
TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(CURDIR)/../rtl/rv32i.v $(CURDIR)/../rtl/rv_decode.v $(CURDIR)/../rtl/rv_alu.v \
	$(CURDIR)/../rtl/rv_regs.v $(CURDIR)/../rtl/enreg.v
COCOTB_TOPLEVEL = rv32i
COCOTB_TEST_MODULES = test_lockstep
# A fixed seed, so a run is repeatable and the coverage check always sees the same tests.
export COCOTB_RANDOM_SEED = $(SEED)
SIM_BUILD = $(CURDIR)/../build/cocotb
COCOTB_RESULTS_FILE = $(SIM_BUILD)/results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
