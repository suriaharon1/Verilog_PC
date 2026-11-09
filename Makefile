# Verilog_PC- top-level Makefile
#
#   make lint      Verilator -Wall lint of the core
#   make unit      build and run module unit tests (alu, regfile)
#   make sim       build the core testbench (build/sim/Vcore_top)
#   make tests     build the rv32ui riscv-tests (ELF + flat binary)
#   make test      run the full rv32ui suite
#   make test-stress  same, with random bus wait states
#   make clean

VERILATOR    ?= verilator
RISCV_PREFIX ?= riscv64-unknown-elf-
RV_GCC       := $(RISCV_PREFIX)gcc
RV_OBJCOPY   := $(RISCV_PREFIX)objcopy

BUILD     := build
CORE_DIR  := rtl/core
CORE_SRCS := $(wildcard $(CORE_DIR)/*.v)
CORE_HDRS := $(wildcard $(CORE_DIR)/*.vh)

VFLAGS := -Wall -I$(CORE_DIR) --x-assign unique --x-initial unique
VCFLAGS := -CFLAGS "-O2 -std=c++17"

# FST waveform support needs lz4 (Homebrew installs it outside the default paths)
BREW_PREFIX := $(shell brew --prefix 2>/dev/null)
ifneq ($(BREW_PREFIX),)
FST_FLAGS := -CFLAGS "-I$(BREW_PREFIX)/include" -LDFLAGS "-L$(BREW_PREFIX)/lib"
endif

# ----------------------------------------------------------------------
# riscv-tests
# ----------------------------------------------------------------------
RVTESTS   := tests/riscv-tests
RV_MARCH  := -march=rv32i_zicsr_zifencei -mabi=ilp32
RV_TFLAGS := -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles \
             -I$(RVTESTS)/env/p -I$(RVTESTS)/isa/macros/scalar -T$(RVTESTS)/env/p/link.ld

include $(RVTESTS)/isa/rv32ui/Makefrag

TEST_DIR  := $(BUILD)/tests
UI_ELFS   := $(addprefix $(TEST_DIR)/rv32ui-p-,$(addsuffix .elf,$(rv32ui_sc_tests)))
UI_BINS   := $(UI_ELFS:.elf=.bin)

# ----------------------------------------------------------------------

.PHONY: all lint unit sim tests test test-stress clean

all: lint unit sim tests

lint:
	$(VERILATOR) --lint-only $(VFLAGS) --top-module core_top $(CORE_SRCS)

# Unit tests: one Verilator build per module under test
UNIT_MODULES := alu regfile

define unit_template
$(BUILD)/unit/$(1)/V$(1): $(CORE_DIR)/$(1).v sim/unit/tb_$(1).cpp $(CORE_HDRS)
	@mkdir -p $(BUILD)/unit/$(1)
	$(VERILATOR) $(VFLAGS) $(VCFLAGS) --cc --exe --build -j 0 --top-module $(1) \
	    -Mdir $(BUILD)/unit/$(1) $(CORE_DIR)/$(1).v sim/unit/tb_$(1).cpp -o V$(1)
endef
$(foreach m,$(UNIT_MODULES),$(eval $(call unit_template,$(m))))

unit: $(foreach m,$(UNIT_MODULES),$(BUILD)/unit/$(m)/V$(m))
	@for m in $(UNIT_MODULES); do $(BUILD)/unit/$$m/V$$m || exit 1; done

# Core testbench
SIM := $(BUILD)/sim/Vcore_top

$(SIM): $(CORE_SRCS) $(CORE_HDRS) sim/tb_core.cpp
	@mkdir -p $(BUILD)/sim
	$(VERILATOR) $(VFLAGS) $(VCFLAGS) --cc --exe --build -j 0 --trace-fst $(FST_FLAGS) \
	    --top-module core_top -Mdir $(BUILD)/sim $(CORE_SRCS) sim/tb_core.cpp -o Vcore_top

sim: $(SIM)

# riscv-tests
$(TEST_DIR)/rv32ui-p-%.elf: $(RVTESTS)/isa/rv32ui/%.S
	@mkdir -p $(@D)
	$(RV_GCC) $(RV_MARCH) $(RV_TFLAGS) $< -o $@

$(TEST_DIR)/%.bin: $(TEST_DIR)/%.elf
	$(RV_OBJCOPY) -O binary $< $@

tests: $(UI_ELFS) $(UI_BINS)

test: sim tests
	scripts/run_tests.sh rv32ui

test-stress: sim tests
	scripts/run_tests.sh rv32ui --random-wait --seed 7

clean:
	rm -rf $(BUILD)
