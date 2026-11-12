# Core interface

The testbench (`tb/tb.sv`) drives one module, `core`, in `rtl/core.sv`:

```systemverilog
module core (
    input  logic        clk,
    input  logic        rst_n,       // active-low; PC resets to 32'h8000_0000
    output logic        imem_req,    // one cycle: read the 16-byte line at imem_addr
    output logic [31:0] imem_addr,   // line address (bits [3:0] zero)
    input  logic        imem_rvalid, // imem_rdata holds the next word of the line
    input  logic [31:0] imem_rdata,
    output logic [31:0] dmem_addr,   // byte address; memory ignores bits [1:0]
    output logic [31:0] dmem_wdata,  // store data already on its byte lanes
    output logic [3:0]  dmem_wstrb,  // byte enables; nonzero means store this cycle
    input  logic [31:0] dmem_rdata,  // the word at last cycle's dmem_addr
    output logic        fetch,       // IF passed an instruction to ID this cycle
    output logic        retire       // one instruction completed (left WB) this cycle
);
```

- Memory is 64 KB at `0x8000_0000`, loaded from the test's hex file. Data memory is synchronous, like block RAM: `dmem_rdata` is the word at the previous cycle's `dmem_addr`, and stores land on the rising edge.
- Instruction memory sits behind the core's cache. After a request in cycle k it returns the line's four words in address order in cycles k+N+1 to k+N+4, where N is `+imem_latency=N` (default 10). The core makes no new request until the fourth word arrives. Stores do not update the instruction cache (no `fence.i`).
- Loads read the whole word and pick their bytes from `dmem_addr[1:0]`. Stores shift data onto the lanes and set the matching strobes (`sb` at offset 2 drives `wstrb = 4'b0100`).
- `fence` runs as a no-op. `ecall`, `ebreak` and CSRs are not needed by the tests.
- A test ends when the core stores to `tohost` (`0x8000_FFF0`): 1 is a pass; `(n << 1) | 1` is a failure in test case `n`. No result in 100,000 cycles is a failure. A simulation assertion (`ERROR` line) also fails the test.
- The testbench counts cycles, `retire` and `fetch` pulses and line requests from reset release to the `tohost` store and prints them with the pass: `PASS <hex> cycles=N instret=M CPI=N/M fetches=F fills=R`. The store itself has not retired yet, and the count includes the pipeline fill. `make sim` adds a total line with the cache hit rate, 1 - R/F.

## Board

`fpga/top.sv` wires the same ports to 64 KB of dual-port block RAM (`fpga/ram.sv`): port A serves line fills, one word per cycle, the first in cycle k+2 (the testbench's `+imem_latency=1`); port B is the data port.
