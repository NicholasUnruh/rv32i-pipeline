# Core interface

The testbench (`tb/tb.sv`) drives one module, `core`, in `rtl/core.sv`:

```systemverilog
module core #(
    parameter int DCACHE_INDEX_BITS = 5,   // data cache: 2^bits sets (at least 1 bit),
    parameter int DCACHE_WAYS = 2,         // ways per set,
    parameter int DCACHE_OFFSET_BITS = 4   // 2^bits-byte lines (at least 3 bits)
) (
    input  logic        clk,
    input  logic        rst_n,       // active-low; PC resets to 32'h8000_0000
    output logic        imem_req,    // one cycle: read the 16-byte line at imem_addr
    output logic [31:0] imem_addr,   // line address (bits [3:0] zero)
    input  logic        imem_rvalid, // imem_rdata holds the next word of the line
    input  logic [31:0] imem_rdata,
    output logic        dmem_req,    // one cycle: read the data line at dmem_addr
    output logic [31:0] dmem_addr,   // line address, or the word a write goes to
    input  logic        dmem_rvalid, // dmem_rdata holds the next word of the line
    input  logic [31:0] dmem_rdata,
    output logic [31:0] dmem_wdata,  // write data already on its byte lanes
    output logic [3:0]  dmem_wstrb,  // byte enables; nonzero means write this cycle
    output logic        fetch,       // IF passed an instruction to ID this cycle
    output logic        retire       // one instruction completed (left WB) this cycle
);
```

- Memory is 64 KB at `0x8000_0000`, loaded from the program's hex file. Both caches refill through line ports: after a request in cycle k, memory returns the line's words in address order in cycles k+N+1 onwards, one per cycle, where N is `+mem_latency=N` (default 10). Instruction lines are four words; data lines have 2^(`DCACHE_OFFSET_BITS` − 2). A cache makes no new request until its line is in.
- Writes are posted: memory takes one word per cycle on `dmem_wstrb`, from a dirty-line writeback (all strobes) or an I/O store. Addresses below `0x8000_0000` are I/O and bypass the data cache; there are no I/O loads.
- Stores do not update the instruction cache (no `fence.i`), and dirty data lines are not visible to instruction fetch.
- Loads pick their bytes from the address's low bits. Stores shift data onto the lanes and set the matching strobes (`sb` at offset 2 has strobes `4'b0100`).
- `fence` runs as a no-op. `ecall`, `ebreak` and CSRs are not needed by the tests.
- A test ends when the core stores to `tohost`, the I/O word at `0x4000_0000`: 1 is a pass; `(n << 1) | 1` is a failure in test case `n`. No result in 100,000 cycles (`+max_cycles=N`) is a failure. A simulation assertion (`ERROR` line) also fails the test.
- The testbench counts cycles, `retire` and `fetch` pulses, instruction line requests, and the data cache's accesses, hits, misses and dirty writebacks (from events inside `rtl/dcache.sv`) from reset release to the `tohost` store, and prints them with the pass: `PASS <hex> cycles=N instret=M CPI=N/M fetches=F fills=R daccesses=A dhits=H dmisses=M dwritebacks=W`. The store itself has not retired yet, and the count includes the pipeline fill. `make sim` adds a total line with both hit rates.

## Board

`fpga/top.sv` wires the same ports to 64 KB of dual-port block RAM (`fpga/ram.sv`): port A serves instruction line fills, one word per cycle, the first in cycle k+2 (the testbench's `+mem_latency=1`); port B serves data line fills the same way and takes the posted writes. I/O writes skip the RAM.
