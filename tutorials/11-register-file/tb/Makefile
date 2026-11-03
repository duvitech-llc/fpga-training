# Run through "make cocotb" in the parent directory.
SIM ?= icarus
WIDTH ?= 8
REGS ?= 4
TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(CURDIR)/../rtl/regfile.v $(CURDIR)/../rtl/enreg.v
COMPILE_ARGS += -Pregfile.WIDTH=$(WIDTH) -Pregfile.REGS=$(REGS)
COCOTB_TOPLEVEL = regfile
COCOTB_TEST_MODULES = test_regfile
# One directory per size, otherwise changing a parameter would not recompile.
SIM_BUILD = $(CURDIR)/../build/cocotb-$(WIDTH)-$(REGS)
COCOTB_RESULTS_FILE = $(SIM_BUILD)/results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
