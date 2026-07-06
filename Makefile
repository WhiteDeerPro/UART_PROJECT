# ============================================================================
# UART testbench - VCS/Verdi Makefile
# ============================================================================

# --- Environment -------------------------------------------------------------
ifndef VCS_HOME
VCS_HOME := /opt/synopsys/vcs
endif

# --- Files and arguments -----------------------------------------------------
TB        ?= uart_1
FLIST     ?= flists/$(TB)_vcs.f
TOP       ?= uart_tb
FSDB_FILE ?= $(TB).fsdb
SIMV      ?= simv
WORK_DIR  ?= build/$(TB)
MAX_CYCLES ?= 4000000

# VCS compile options
VCS_FLAGS := -sverilog \
             -debug_access+all \
             -debug_region+cell+encrypt \
             -lca -kdb \
             -full64 \
             -timescale=1ns/1ps \
             +define+DUMP_FSDB \
             -LDFLAGS -Wl,--no-as-needed

# Simulation runtime options
SIM_FLAGS := +fsdb+autoflush +fsdb+all +fsdb+struct +fsdb+mda +max_cycles=$(MAX_CYCLES)

# --- Targets ----------------------------------------------------------------
.PHONY: all compile run verdi verdi_sch clean rerun \
        uart_0 uart_1 uart_2 uart_0_verdi uart_1_verdi uart_2_verdi \
        help

all: clean compile run

compile: $(FLIST)
	mkdir -p $(WORK_DIR)
	vcs $(VCS_FLAGS) -f $(FLIST) -top $(TOP) \
	    -o $(WORK_DIR)/$(SIMV) -Mdir=$(WORK_DIR)/csrc \
	    -l $(WORK_DIR)/compile.log

run:
	@if [ ! -f $(WORK_DIR)/$(SIMV) ]; then \
		echo "Error: $(WORK_DIR)/$(SIMV) not found. Run 'make compile' first."; \
		exit 1; \
	fi
	cd $(WORK_DIR) && ./$(SIMV) $(SIM_FLAGS) -l sim.log

verdi:
	@if [ ! -f $(WORK_DIR)/$(FSDB_FILE) ]; then \
		echo "Error: $(WORK_DIR)/$(FSDB_FILE) not found. Run 'make run' first."; \
		exit 1; \
	fi
	verdi -sv -f $(FLIST) -top $(TOP) -ssf $(WORK_DIR)/$(FSDB_FILE) &

verdi_sch:
	mkdir -p $(WORK_DIR)
	verdi -sv -f $(FLIST) -top $(TOP) &

clean:
	rm -rf build simv* csrc* *.log *.key *.vpd *.vdb *.fsdb \
	       verdiLog novas.* ucli.key

rerun: clean compile run verdi

uart_0:
	$(MAKE) rerun TB=uart_0 FSDB_FILE=uart_0.fsdb MAX_CYCLES=8000000

uart_1:
	$(MAKE) rerun TB=uart_1 FSDB_FILE=uart_1.fsdb MAX_CYCLES=4000000

uart_2:
	$(MAKE) rerun TB=uart_2 FSDB_FILE=uart_2.fsdb MAX_CYCLES=2000000

uart_0_verdi:
	$(MAKE) verdi TB=uart_0 FSDB_FILE=uart_0.fsdb

uart_1_verdi:
	$(MAKE) verdi TB=uart_1 FSDB_FILE=uart_1.fsdb

uart_2_verdi:
	$(MAKE) verdi TB=uart_2 FSDB_FILE=uart_2.fsdb

help:
	@echo "Usage:"
	@echo "  make uart_1        # compile, run, and open Verdi for default 256-byte IRQ test"
	@echo "  make compile run   # use TB=$(TB), FLIST=$(FLIST), TOP=$(TOP)"
	@echo "  make verdi         # open Verdi with WORK_DIR=$(WORK_DIR)/$(FSDB_FILE)"
	@echo "  make clean"
