// Formal harness for rtl/dcache.sv (run with formal/dcache.sby).
//
// The environment drives the cache the way the core does: a new access enters MEM
// only when the cache is not stalling, and its address is the one the cache read
// its arrays with a cycle earlier (ex_addr). Memory returns a requested line after
// LATENCY cycles, one word per cycle, and takes posted word writes.
//
// To check data without modelling all of memory, the proof follows one word at an
// arbitrary cached address A (chosen by the solver). `expected` is what a program
// would read at A: its initial value, updated by every completed store to A. `mem_a`
// is memory's copy of A: written by writebacks, read by refills. Every other word of
// memory returns arbitrary data.
//
// Addresses are confined to 64 cached bytes at 0x8000_0000 and 64 I/O bytes at 0, so
// each set sees four distinct tags (enough for conflicts in two ways). The cache only
// compares tags for equality, so wider tags add solver work but no new behaviour.
//
// Properties:
//   - a completed load from A returns `expected` (no lost dirty data, no stale fill,
//     correct store-to-load bypass);
//   - an I/O store goes to memory unchanged, in the cycle it completes;
//   - the cache never stalls longer than one dirty writeback, the line request,
//     the latency and the fill: (W + 1) + 1 + LATENCY + W + 2 cycles in a row.
// The solver drives the inputs: the next access and the words memory returns.
module dcache_formal (
    input logic clk,
    input logic [31:2] next_addr_word,
    input logic [1:0] next_offset,
    input logic next_read,
    input logic next_write,
    input logic [31:0] next_wdata,
    input logic [3:0] next_wstrb,
    input logic [31:0] other_word
);
  localparam int INDEX_BITS = 1;
  localparam int WAYS = 2;
  localparam int OFFSET_BITS = 3;
  localparam int W = 1 << (OFFSET_BITS - 2);  // words per line
  localparam int LATENCY = 2;
  localparam int MAX_STALL = (W + 1) + 1 + LATENCY + W + 2;

  // Reset for the first cycle only.
  logic started = 1'b0;
  always_ff @(posedge clk) started <= 1'b1;
  wire rst_n = started;

  // ---------------------------------------------------------------- core side
  logic read, write, stall;
  logic [31:0] addr, wdata, rdata;
  logic [3:0] wstrb;

  // MEM's access: replaced only when the cache is not stalling, by the access
  // whose address went to ex_addr the cycle before.
  always_ff @(posedge clk)
    if (!rst_n) begin
      read <= 1'b0;
      write <= 1'b0;
      addr <= 32'h8000_0000;
      wdata <= '0;
      wstrb <= '0;
    end else if (!stall) begin
      read <= next_read;
      write <= next_write;
      addr <= {next_addr_word, next_offset};
      wdata <= next_wdata;
      wstrb <= next_write ? next_wstrb : 4'b0;
    end

  always_comb begin
    assume (!(next_read && next_write));
    assume (!next_write || next_wstrb != 4'b0);
    assume (!next_read || next_addr_word[31]);  // the core has no I/O loads
    assume (next_addr_word[30:6] == '0);
  end

  // ---------------------------------------------------------------- memory side
  logic mem_req, mem_rvalid;
  logic [31:0] mem_addr, mem_rdata, mem_wdata;
  logic [3:0] mem_wstrb;

  dcache #(
      .INDEX_BITS(INDEX_BITS),
      .WAYS(WAYS),
      .OFFSET_BITS(OFFSET_BITS)
  ) dut (
      .clk(clk),
      .rst_n(rst_n),
      .ex_addr(next_addr_word),
      .read(read),
      .write(write),
      .addr(addr),
      .wdata(wdata),
      .wstrb(wstrb),
      .rdata(rdata),
      .stall(stall),
      .mem_req(mem_req),
      .mem_addr(mem_addr),
      .mem_rvalid(mem_rvalid),
      .mem_rdata(mem_rdata),
      .mem_wstrb(mem_wstrb),
      .mem_wdata(mem_wdata)
  );

  (* anyconst *) logic [31:2] a;    // the tracked word
  always_comb assume (a[31] && a[30:6] == '0);

  // Both start with the same arbitrary value.
  logic [31:0] mem_a, expected;
  always_comb if (!started) assume (mem_a == expected);

  // Line reads: words in address order, LATENCY cycles after the request.
  logic [31:2] fill_word;
  logic [2:0] fill_wait = '0;
  logic [2:0] fill_left = '0;
  always_ff @(posedge clk) begin
    if (mem_req) begin
      fill_word <= mem_addr[31:2];
      fill_wait <= LATENCY;
      fill_left <= W;
    end else if (fill_wait > 0) begin
      fill_wait <= fill_wait - 1;
    end else if (fill_left > 0) begin
      fill_word <= fill_word + 1'b1;
      fill_left <= fill_left - 1;
    end
  end
  assign mem_rvalid = rst_n && !mem_req && fill_wait == 0 && fill_left > 0;
  assign mem_rdata = fill_word == a ? mem_a : other_word;

  // Posted writes, and the program's view of A.
  wire done = rst_n && !stall;
  always_ff @(posedge clk) begin
    for (int b = 0; b < 4; b++) begin
      if (mem_wstrb[b] && mem_addr[31:2] == a) mem_a[8*b+:8] <= mem_wdata[8*b+:8];
      if (done && write && wstrb[b] && addr[31:2] == a) expected[8*b+:8] <= wdata[8*b+:8];
    end
  end

  // ---------------------------------------------------------------- properties
  logic [3:0] stall_run = '0;
  always_ff @(posedge clk) stall_run <= stall ? stall_run + 1 : 0;

  always_comb
    if (rst_n) begin
      if (done && read && addr[31:2] == a) assert (rdata == expected);
      if (done && write && !addr[31]) assert (mem_wstrb == wstrb && mem_addr == addr
                                              && mem_wdata == wdata);
      assert (!(stall && stall_run == MAX_STALL));  // stall_run counts the cycles before this one
      assert (!(mem_req && fill_left > 0));  // one line in flight at a time
    end

  // Reachability, so the data property is not vacuous within the bmc depth: A is
  // written, evicted dirty, refilled and read back. smtbmc's cover search is too
  // slow at this depth, so the reach task asserts the opposite and lets bmc3 find
  // the trace; its "failure" is the witness.
  logic a_written_back = 1'b0;
  always_ff @(posedge clk)
    if (mem_wstrb != 4'b0 && mem_addr[31:2] == a && mem_wdata != mem_a) a_written_back <= 1'b1;
`ifdef REACH
  always_comb assert (!(a_written_back && done && read && addr[31:2] == a));
`endif
  always_comb cover (stall_run == MAX_STALL);  // the bound is tight
endmodule
