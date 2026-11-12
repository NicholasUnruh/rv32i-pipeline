// Runs one riscv-tests program on `core`: +hex=<file> [+imem_latency=N]. Prints one
// PASS or FAIL line with the cycles, retired instructions, fetches and cache line
// fills from reset release to the tohost store.
`timescale 1ns / 1ps

module tb;
  localparam logic [31:0] BASE = 32'h8000_0000;
  localparam logic [31:0] TOHOST = 32'h8000_FFF0;
  localparam int WORDS = 16384;  // 64 KB
  localparam int MAX_CYCLES = 100_000;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic [31:0] mem[WORDS];
  logic imem_req, imem_rvalid, fetch, retire;
  logic [31:0] imem_addr, imem_rdata, dmem_addr, dmem_wdata, dmem_rdata;
  logic [3:0] dmem_wstrb;
  string hex;
  int imem_latency = 10;  // extra cycles before a requested line's first word
  int cycles = 0;
  // Counted from reset release
  int run_cycles = 0;
  int instret = 0;
  int fetches = 0;
  int fills = 0;

  core dut (
      .clk(clk),
      .rst_n(rst_n),
      .imem_req(imem_req),
      .imem_addr(imem_addr),
      .imem_rvalid(imem_rvalid),
      .imem_rdata(imem_rdata),
      .dmem_addr(dmem_addr),
      .dmem_wdata(dmem_wdata),
      .dmem_wstrb(dmem_wstrb),
      .dmem_rdata(dmem_rdata),
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

  // Instruction memory: a line request in cycle k returns the line's four words in
  // cycles k+imem_latency+1 to k+imem_latency+4.
  logic [31:0] fill_addr;
  int fill_wait = 0;
  int fill_left = 0;

  always @(posedge clk) begin
    imem_rvalid <= 1'b0;
    if (fill_left > 0) begin
      if (fill_wait > 1) begin
        fill_wait <= fill_wait - 1;
      end else begin
        imem_rvalid <= 1'b1;
        imem_rdata <= in_range(fill_addr) ? mem[word(fill_addr)] : 32'hx;
        fill_addr <= fill_addr + 32'd4;
        fill_left <= fill_left - 1;
      end
    end
    if (rst_n && imem_req) begin
      if (fill_left != 0) $fatal(1, "line request while a fill is in flight");
      fill_addr <= imem_addr;
      fill_wait <= imem_latency;
      fill_left <= 4;
    end
  end

  always @(posedge clk) begin
    if (rst_n && dmem_wstrb != 4'b0) begin
      if ((dmem_addr & ~32'h3) == TOHOST) begin
        if (dmem_wdata == 32'd1)
          $display("PASS %s cycles=%0d instret=%0d CPI=%0.3f fetches=%0d fills=%0d", hex,
                   run_cycles, instret, real'(run_cycles) / instret, fetches, fills);
        else $display("FAIL %s: test %0d", hex, dmem_wdata >> 1);
        $finish;
      end
      if (!in_range(dmem_addr)) begin
        $display("FAIL %s: store to %h outside memory", hex, dmem_addr);
        $finish;
      end
      for (int b = 0; b < 4; b++)
        if (dmem_wstrb[b]) mem[word(dmem_addr)][8*b+:8] <= dmem_wdata[8*b+:8];
    end
    // Data reads are synchronous: the word at this cycle's address, next cycle.
    dmem_rdata <= in_range(dmem_addr) ? mem[word(dmem_addr)] : 32'hx;
    cycles <= cycles + 1;
    if (rst_n) begin
      run_cycles <= run_cycles + 1;
      instret <= instret + int'(retire);
      fetches <= fetches + int'(fetch);
      fills <= fills + int'(imem_req);
    end
    if (cycles >= MAX_CYCLES) begin
      $display("FAIL %s: no result in %0d cycles", hex, MAX_CYCLES);
      $finish;
    end
  end

  initial begin
    if (!$value$plusargs("hex=%s", hex)) $fatal(1, "usage: +hex=<file> [+imem_latency=N]");
    void'($value$plusargs("imem_latency=%d", imem_latency));
    if (imem_latency < 1) $fatal(1, "imem_latency must be at least 1");
    for (int i = 0; i < WORDS; i++) mem[i] = 32'h0;
    $readmemh(hex, mem);
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
  end
endmodule
