# Core interface

The testbench (`tb/tb.sv`) drives one module, `core`, in `rtl/core.sv`:

```systemverilog
module core (
    input  logic        clk,
    input  logic        rst_n,       // active-low; PC resets to 32'h8000_0000
    output logic [31:0] imem_addr,   // byte address of the instruction to fetch
    input  logic [31:0] imem_rdata,  // combinational: valid in the same cycle
    output logic [31:0] dmem_addr,   // byte address; memory ignores bits [1:0]
    output logic [31:0] dmem_wdata,  // store data already on its byte lanes
    output logic [3:0]  dmem_wstrb,  // byte enables; nonzero means store this cycle
    input  logic [31:0] dmem_rdata,  // combinational: the word at dmem_addr
    output logic        retire       // one instruction completed (left WB) this cycle
);
```

- Memory is 64 KB at `0x8000_0000`, loaded from the test's hex file. Reads are combinational; stores land on the rising edge.
- Loads read the whole word and pick their bytes from `dmem_addr[1:0]`. Stores shift data onto the lanes and set the matching strobes (`sb` at offset 2 drives `wstrb = 4'b0100`).
- `fence` runs as a no-op. `ecall`, `ebreak` and CSRs are not needed by the tests.
- A test ends when the core stores to `tohost` (`0x8000_FFF0`): 1 is a pass; `(n << 1) | 1` is a failure in test case `n`. No result in 100,000 cycles is a failure. A simulation assertion (`ERROR` line) also fails the test.
- The testbench counts cycles and `retire` pulses from reset release to the `tohost` store and prints them with the pass: `PASS <hex> cycles=N instret=M CPI=N/M`. The store itself has not retired yet, and the count includes the pipeline fill. `make sim` adds a total line.

## Synchronous memory

FPGA block RAM returns data one cycle after the address. The combinational model keeps the single-cycle core simple. Moving to registered memory is part of the board milestone, where the fetch stage issues the address a cycle ahead.
