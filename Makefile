.PHONY: check tests sim bench lint synth build program toolchain clean

XPACK := xpack-riscv-none-elf-gcc-15.2.0-1
XPACK_URL := https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v15.2.0-1/$(XPACK)-linux-x64.tar.gz
RISCV ?= $(HOME)/.local/opt/$(XPACK)/bin/riscv-none-elf-

ISA := third_party/riscv-tests/isa
# fence_i needs Zifencei; ma_data needs misaligned access support.
SKIP := fence_i ma_data
TESTS := $(filter-out $(SKIP),$(basename $(notdir $(wildcard $(ISA)/rv32ui/*.S))))
HEX := $(TESTS:%=build/tests/%.hex)
RTL := $(wildcard rtl/*.sv)
QUARTUS := build/quartus

# Run before every commit.
check: sim bench lint synth

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

# Runs every test on the core; fails unless all pass. Prints cycles, CPI and cache
# statistics per test and in total.
sim: $(HEX) $(RTL) tb/tb.sv
	iverilog -g2012 -s tb -o build/tb.vvp tb/tb.sv $(RTL)
	rm -f build/sim.log
	for t in $(TESTS); do \
		timeout 60 vvp -n build/tb.vvp +hex=build/tests/$$t.hex | grep -m1 -E '^(PASS|FAIL|ERROR)' >> build/sim.log \
			|| echo "FAIL build/tests/$$t.hex: no result" >> build/sim.log; \
	done
	cat build/sim.log
	awk -F'[ =]' '/^PASS/ {c += $$4; i += $$6; f += $$10; m += $$12; a += $$14; h += $$16; w += $$20} END {if (i) printf "total cycles=%d instret=%d CPI=%.3f fetches=%d fills=%d ihit_rate=%.4f daccesses=%d dhit_rate=%.4f dwritebacks=%d\n", c, i, c / i, f, m, 1 - m / f, a, h / a, w}' build/sim.log
	test "$$(grep -c '^PASS' build/sim.log)" -eq $(words $(TESTS))

# Bare-metal C benchmark for CPI comparisons.
build/bench/bench.elf: tests/bench/bench.c tests/bench/crt0.S tests/env/link.ld
	@mkdir -p build/bench
	$(RISCV)gcc -march=rv32i -mabi=ilp32 -O2 -static -nostdlib -nostartfiles \
		-Wl,--no-warn-rwx-segments -Ttests/env/link.ld -o $@ tests/bench/crt0.S tests/bench/bench.c -lgcc

build/bench/bench.hex: build/bench/bench.elf
	$(RISCV)objcopy -O binary $< build/bench/bench.bin
	python3 scripts/bin2hex.py build/bench/bench.bin $@

bench: build/bench/bench.hex $(RTL) tb/tb.sv
	iverilog -g2012 -s tb -o build/tb.vvp tb/tb.sv $(RTL)
	timeout 60 vvp -n build/tb.vvp +hex=$< | grep -m1 -E '^(PASS|FAIL|ERROR)' | tee build/bench.log
	grep -q '^PASS' build/bench.log

lint:
	verilator --lint-only -Wall --top-module core $(RTL)
	verilator --lint-only -Wall --top-module top $(RTL) $(wildcard fpga/*.sv)

synth:
	mkdir -p build
	yosys -q -l build/synth.log -p 'read_verilog -sv $(RTL); synth_intel_alm -family cyclonev -top core; stat'

# Quartus compile for the DE1-SoC with the C benchmark in block RAM; fails on any
# timing violation or misplaced pin.
build: build/bench/bench.hex
	mkdir -p $(QUARTUS)
	cp quartus/* $(QUARTUS)/
	cp build/bench/bench.hex $(QUARTUS)/program.hex
	cd $(QUARTUS) && quartus_sh --flow compile rv32i
	python3 scripts/quartus_gate.py timing $(QUARTUS)/output_files/rv32i.sta.rpt
	python3 scripts/quartus_gate.py pins $(QUARTUS)/output_files/rv32i.pin quartus/rv32i.qsf

# The HPS is device 1 on the JTAG chain; the FPGA is device 2.
program:
	quartus_pgm --mode=jtag --cable=1 -o "p;$(QUARTUS)/output_files/rv32i.sof@2"

clean:
	rm -rf build
