.PHONY: check tests sim lint synth toolchain clean

XPACK := xpack-riscv-none-elf-gcc-15.2.0-1
XPACK_URL := https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v15.2.0-1/$(XPACK)-linux-x64.tar.gz
RISCV ?= $(HOME)/.local/opt/$(XPACK)/bin/riscv-none-elf-

ISA := third_party/riscv-tests/isa
# fence_i needs Zifencei; ma_data needs misaligned access support.
SKIP := fence_i ma_data
TESTS := $(filter-out $(SKIP),$(basename $(notdir $(wildcard $(ISA)/rv32ui/*.S))))
HEX := $(TESTS:%=build/tests/%.hex)
RTL := $(wildcard rtl/*.sv)

# Run before every commit.
check: sim lint synth

toolchain:
	test -x $(RISCV)gcc || (mkdir -p $(HOME)/.local/opt && \
		curl -fsSL --max-time 600 $(XPACK_URL) | tar -xz -C $(HOME)/.local/opt)

# Keep the ELFs for objdump when a test fails.
.PRECIOUS: build/tests/%.elf

tests: $(HEX)

build/tests/%.elf: $(ISA)/rv32ui/%.S tests/env/riscv_test.h tests/env/link.ld
	@mkdir -p build/tests
	$(RISCV)gcc -march=rv32i -mabi=ilp32 -static -nostdlib -nostartfiles \
		-Wl,--no-warn-rwx-segments -Itests/env -I$(ISA)/macros/scalar \
		-Ttests/env/link.ld -o $@ $<

build/tests/%.hex: build/tests/%.elf
	$(RISCV)objcopy -O binary $< build/tests/$*.bin
	python3 scripts/bin2hex.py build/tests/$*.bin $@

# Runs every test on the core; fails unless all pass. Prints cycles and CPI per test
# and in total.
sim: $(HEX) $(RTL) tb/tb.sv
	iverilog -g2012 -s tb -o build/tb.vvp tb/tb.sv $(RTL)
	rm -f build/sim.log
	for t in $(TESTS); do \
		timeout 60 vvp -n build/tb.vvp +hex=build/tests/$$t.hex | grep -m1 -E '^(PASS|FAIL|ERROR)' >> build/sim.log \
			|| echo "FAIL build/tests/$$t.hex: no result" >> build/sim.log; \
	done
	cat build/sim.log
	awk -F'[ =]' '/^PASS/ {c += $$4; i += $$6} END {if (i) printf "total cycles=%d instret=%d CPI=%.3f\n", c, i, c / i}' build/sim.log
	test "$$(grep -c '^PASS' build/sim.log)" -eq $(words $(TESTS))

lint:
	verilator --lint-only -Wall --top-module core $(RTL)

synth:
	mkdir -p build
	yosys -q -l build/synth.log -p 'read_verilog -sv $(RTL); synth_intel_alm -family cyclonev -top core; stat'

clean:
	rm -rf build
