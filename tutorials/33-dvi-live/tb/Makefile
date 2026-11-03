# Run through "make cocotb" in the parent directory, once for each TEST:
#   tmds     the TMDS encoder alone, against the Python model in tmds_model.py
#   display  wb_display.v alone: a queued frame reads the buffer it was given
TEST ?= tmds
SIM ?= icarus
TOPLEVEL_LANG = verilog
ifeq ($(TEST),display)
VERILOG_SOURCES = $(CURDIR)/../rtl/wb_display.v $(CURDIR)/../rtl/sync_2ff.v
COCOTB_TOPLEVEL = wb_display
COCOTB_TEST_MODULES = test_display
# A small frame, as test_display.py expects: 16 by 2 pixels, 8 words.
COMPILE_ARGS += -Pwb_display.WIDTH=16 -Pwb_display.HEIGHT=2
else
VERILOG_SOURCES = $(CURDIR)/../rtl/tmds_encoder.v
COCOTB_TOPLEVEL = tmds_encoder
COCOTB_TEST_MODULES = test_tmds
endif
SIM_BUILD = $(CURDIR)/../build/cocotb_$(TEST)
COCOTB_RESULTS_FILE = $(SIM_BUILD)/results.xml

include $(shell cocotb-config --makefiles)/Makefile.sim
