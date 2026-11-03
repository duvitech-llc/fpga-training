# Run through "make cocotb" in the parent directory.
SIM ?= icarus
SEED ?= 18
TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(CURDIR)/../rtl/cpu_top.v $(CURDIR)/../rtl/cpu.v $(CURDIR)/../rtl/decode.v \
	$(CURDIR)/../rtl/alu_flags.v $(CURDIR)/../rtl/regfile.v $(CURDIR)/../rtl/enreg.v
COCOTB_TOPLEVEL = cpu_top
COCOTB_TEST_MODULES = test_cpu
# A fixed seed, so a run is repeatable and the coverage check always sees the same tests.
export COCOTB_RANDOM_SEED = $(SEED)
SIM_BUILD = $(CURDIR)/../build/cocotb
COCOTB_RESULTS_FILE = $(SIM_BUILD)/results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
