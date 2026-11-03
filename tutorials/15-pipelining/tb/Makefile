# Run through "make cocotb" in the parent directory.
SIM ?= icarus
WIDTH ?= 32
STAGES ?= 2
TOPLEVEL_LANG = verilog
VERILOG_SOURCES = $(CURDIR)/../rtl/pipe_adder.v
COMPILE_ARGS += -Ppipe_adder.WIDTH=$(WIDTH) -Ppipe_adder.STAGES=$(STAGES)
COCOTB_TOPLEVEL = pipe_adder
COCOTB_TEST_MODULES = test_pipe_adder
# One directory per setting, otherwise changing one would not recompile the design.
SIM_BUILD = $(CURDIR)/../build/cocotb-$(WIDTH)-$(STAGES)
COCOTB_RESULTS_FILE = $(SIM_BUILD)/results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
