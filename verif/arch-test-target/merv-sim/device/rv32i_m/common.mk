# riscv-arch-test target for the merv simulator.
TARGET_SIM   ?= merv-sim
TARGET_FLAGS ?= $(RISCV_TARGET_FLAGS)

RISCV_PREFIX   ?= riscv64-unknown-elf-
RISCV_GCC      ?= $(RISCV_PREFIX)gcc
RISCV_OBJDUMP  ?= $(RISCV_PREFIX)objdump
RISCV_GCC_OPTS ?= -static -mcmodel=medany -g -fvisibility=hidden -nostdlib -nostartfiles -march=rv32ima_zifencei_zicsr -mabi=ilp32 -DXLEN=$(XLEN) $(RVTEST_DEFINES)

# Newer binutils reject `la x0, sym` which some tests generate for an x0
# destination, it's architecturally a no-op so replace it with two nops.
COMPILE_TARGET=\
	$$(RISCV_GCC) -E $(1) $$(RISCV_GCC_OPTS) \
		-I$(ROOTDIR)/riscv-test-env/ \
		-I$(ROOTDIR)/riscv-test-env/p/ \
		-I$(TARGETDIR)/$(RISCV_TARGET)/ $$< | \
		sed -E 's/\bla x0,[^;]*/nop; nop/g' > $$@.S && \
	$$(RISCV_GCC) $$(RISCV_GCC_OPTS) \
		-T$(TARGETDIR)/$(RISCV_TARGET)/env/linkmono.ld $$@.S \
		-o $$@ && \
	$$(RISCV_OBJDUMP) -d $$@ > $$@.objdump

RUN_TARGET=\
	$(TARGET_SIM) $(TARGET_FLAGS) --compliance --elf $(<) --max-steps 10000000 \
		--signature $(*).signature.output --trace-last 50 2> $(@)
