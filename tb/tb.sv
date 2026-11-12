// Runs one program on `core`: +hex=<file> [+mem_latency=N] [+max_cycles=N]. Prints
// one PASS or FAIL line with the cycles, retired instructions, instruction fetches
// and line fills, and data cache accesses, hits, misses and writebacks, from reset
// release to the tohost store. The data cache geometry comes from the parameters.
`timescale 1ns / 1ps

module tb #(
    parameter int DCACHE_INDEX_BITS = 5,
    parameter int DCACHE_WAYS = 2,
    parameter int DCACHE_OFFSET_BITS = 4
);
  localparam logic [31:0] BASE = 32'h8000_0000;
  localparam logic [31:0] TOHOST = 32'h4000_0000;  // I/O: not cached
  localparam int WORDS = 16384;  // 64 KB
  localparam int DLINE_WORDS = 1 << (DCACHE_OFFSET_BITS - 2);

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic [31:0] mem[WORDS];
  logic imem_req, imem_rvalid, dmem_req, dmem_rvalid, fetch, retire;
  logic [31:0] imem_addr, imem_rdata, dmem_addr, dmem_wdata, dmem_rdata, ifill_addr, dfill_addr;
  logic [3:0] dmem_wstrb;
  string hex;
  int mem_latency = 10;  // cycles between a line request and its first word, less one
  int max_cycles = 100_000;
  int cycles = 0;
  // Counted from reset release
  int run_cycles = 0;
  int instret = 0;
  int fetches = 0;
  int fills = 0;
  int daccesses = 0;
  int dhits = 0;
  int dmisses = 0;
  int dwritebacks = 0;

  core #(
      .DCACHE_INDEX_BITS(DCACHE_INDEX_BITS),
      .DCACHE_WAYS(DCACHE_WAYS),
      .DCACHE_OFFSET_BITS(DCACHE_OFFSET_BITS)
  ) dut (
      .clk(clk),
      .rst_n(rst_n),
      .imem_req(imem_req),
      .imem_addr(imem_addr),
      .imem_rvalid(imem_rvalid),
      .imem_rdata(imem_rdata),
      .dmem_req(dmem_req),
      .dmem_addr(dmem_addr),
      .dmem_rvalid(dmem_rvalid),
      .dmem_rdata(dmem_rdata),
      .dmem_wdata(dmem_wdata),
      .dmem_wstrb(dmem_wstrb),
      .fetch(fetch),
      .retire(retire)
  );

  function automatic logic in_range(logic [31:0] addr);
    return addr >= BASE && addr < BASE + 4 * WORDS;
  endfunction

  function automatic int unsigned word(logic [31:0] addr);
    return (addr - BASE) >> 2;
  endfunction

  always #5 clk = ~clk;

  // Both caches refill through the same kind of port, with the same latency.
  line_port #(.LINE_WORDS(4)) iport (
      .clk(clk),
      .rst_n(rst_n),
      .latency(mem_latency),
      .req(imem_req),
      .addr(imem_addr),
      .rvalid(imem_rvalid),
      .word_addr(ifill_addr)
  );
  line_port #(.LINE_WORDS(DLINE_WORDS)) dport (
      .clk(clk),
      .rst_n(rst_n),
      .latency(mem_latency),
      .req(dmem_req),
      .addr(dmem_addr),
      .rvalid(dmem_rvalid),
      .word_addr(dfill_addr)
  );
  assign imem_rdata = in_range(ifill_addr) ? mem[word(ifill_addr)] : 32'hx;
  assign dmem_rdata = in_range(dfill_addr) ? mem[word(dfill_addr)] : 32'hx;

  // Word writes are posted: memory takes one per cycle.
  always @(posedge clk) begin
    if (rst_n && dmem_wstrb != 4'b0) begin
      if (dmem_addr == TOHOST) begin
        if (dmem_wdata == 32'd1)
          $display("PASS %s cycles=%0d instret=%0d CPI=%0.3f fetches=%0d fills=%0d daccesses=%0d dhits=%0d dmisses=%0d dwritebacks=%0d",
                   hex, run_cycles, instret, real'(run_cycles) / instret, fetches, fills,
                   daccesses, dhits, dmisses, dwritebacks);
        else $display("FAIL %s: test %0d", hex, dmem_wdata >> 1);
        $finish;
      end else if (!in_range(dmem_addr)) begin
        $display("FAIL %s: store to %h outside memory", hex, dmem_addr);
        $finish;
      end else begin
        for (int b = 0; b < 4; b++)
          if (dmem_wstrb[b]) mem[word(dmem_addr)][8*b+:8] <= dmem_wdata[8*b+:8];
      end
    end
    cycles <= cycles + 1;
    if (rst_n) begin
      run_cycles <= run_cycles + 1;
      instret <= instret + int'(retire);
      fetches <= fetches + int'(fetch);
      fills <= fills + int'(imem_req);
      daccesses <= daccesses + int'(dut.dc.ev_access);
      dhits <= dhits + int'(dut.dc.ev_hit);
      dmisses <= dmisses + int'(dut.dc.ev_miss);
      dwritebacks <= dwritebacks + int'(dut.dc.ev_writeback);
    end
    if (cycles >= max_cycles) begin
      $display("FAIL %s: no result in %0d cycles", hex, max_cycles);
      $finish;
    end
  end

  initial begin
    if (!$value$plusargs("hex=%s", hex))
      $fatal(1, "usage: +hex=<file> [+mem_latency=N] [+max_cycles=N]");
    void'($value$plusargs("mem_latency=%d", mem_latency));
    void'($value$plusargs("max_cycles=%d", max_cycles));
    if (mem_latency < 1) $fatal(1, "mem_latency must be at least 1");
    for (int i = 0; i < WORDS; i++) mem[i] = 32'h0;
    $readmemh(hex, mem);
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
  end
endmodule

// Line read port: a request in cycle k returns the line's words in address order
// in cycles k+latency+1 onwards, one per cycle. word_addr is the address of the
// word that rvalid announces.
module line_port #(
    parameter int LINE_WORDS = 4
) (
    input  logic        clk,
    input  logic        rst_n,
    input  int          latency,
    input  logic        req,
    input  logic [31:0] addr,
    output logic        rvalid,
    output logic [31:0] word_addr
);
  logic [31:0] next_addr;
  int wait_cycles = 0;
  int left = 0;

  always @(posedge clk) begin
    rvalid <= 1'b0;
    if (left > 0) begin
      if (wait_cycles > 1) begin
        wait_cycles <= wait_cycles - 1;
      end else begin
        rvalid <= 1'b1;
        word_addr <= next_addr;
        next_addr <= next_addr + 32'd4;
        left <= left - 1;
      end
    end
    if (rst_n && req) begin
      if (left != 0) $fatal(1, "line request while a fill is in flight");
      next_addr <= addr;
      wait_cycles <= latency;
      left <= LINE_WORDS;
    end
  end
endmodule
