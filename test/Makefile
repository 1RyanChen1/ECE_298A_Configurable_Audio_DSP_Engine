# TinyTapeout Cocotb simulation Makefile
# See https://docs.cocotb.org/en/stable/quickstart.html

SIM ?= icarus
FST ?= -fst
TOPLEVEL_LANG ?= verilog

SRC_DIR = $(PWD)/../src
PROJECT_SOURCES = project.v packet_parser.v dsp_state_regs.v fir_engine.v output_tx.v

ifneq ($(GATES),yes)
# RTL simulation: compile every production source (not the temporary mac.v)
SIM_BUILD = sim_build/rtl
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))
else
# Gate-level simulation: preserve original GF180 PDK support
SIM_BUILD = sim_build/gl
COMPILE_ARGS += -DGL_TEST
COMPILE_ARGS += -DFUNCTIONAL
COMPILE_ARGS += -DUSE_POWER_PINS
COMPILE_ARGS += -DSIM
COMPILE_ARGS += -DUNIT_DELAY=\#1

VERILOG_SOURCES += $(PDK_ROOT)/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/verilog/primitives.v
VERILOG_SOURCES += $(PDK_ROOT)/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/verilog/gf180mcu_fd_sc_mcu7t5v0.v
VERILOG_SOURCES += $(PWD)/gate_level_netlist.v
endif

# packet_parser.v and fir_engine.v use SystemVerilog syntax.
ifeq ($(SIM),icarus)
COMPILE_ARGS += -g2012
endif
COMPILE_ARGS += -I$(SRC_DIR)

# Existing TinyTapeout wrapper (test/tb.v) and Python Cocotb tests (test/test.py)
VERILOG_SOURCES += $(PWD)/tb.v
TOPLEVEL = tb
COCOTB_TEST_MODULES = test

include $(shell cocotb-config --makefiles)/Makefile.sim
