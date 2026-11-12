// Runs one riscv-tests program on `core`: +hex=<file>. Prints one PASS or FAIL line
// with the cycles and retired instructions from reset release to the tohost store.
`timescale 1ns / 1ps

module tb;
  localparam logic [31:0] BASE = 32'h8000_0000;
  localparam logic [31:0] TOHOST = 32'h8000_FFF0;
  localparam int WORDS = 16384;  // 64 KB
  localparam int MAX_CYCLES = 100_000;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic [31:0] mem[WORDS];
  logic [31:0] imem_addr, imem_rdata, dmem_addr, dmem_wdata, dmem_rdata;
  logic [3:0] dmem_wstrb;
  logic retire;
  string hex;
  int cycles = 0;
  int run_cycles = 0;  // cycles since reset release
  int instret = 0;     // instructions retired since reset release

  core dut (
      .clk(clk),
      .rst_n(rst_n),
      .imem_addr(imem_addr),
      .imem_rdata(imem_rdata),
      .dmem_addr(dmem_addr),
      .dmem_wdata(dmem_wdata),
      .dmem_wstrb(dmem_wstrb),
      .dmem_rdata(dmem_rdata),
      .retire(retire)
  );

  function automatic logic in_range(logic [31:0] addr);
    return addr >= BASE && addr < BASE + 4 * WORDS;
  endfunction

  function automatic int unsigned word(logic [31:0] addr);
    return (addr - BASE) >> 2;
  endfunction

  assign imem_rdata = in_range(imem_addr) ? mem[word(imem_addr)] : 32'hx;
  assign dmem_rdata = in_range(dmem_addr) ? mem[word(dmem_addr)] : 32'hx;

  always #5 clk = ~clk;

  always @(posedge clk) begin
    if (rst_n && dmem_wstrb != 4'b0) begin
      if ((dmem_addr & ~32'h3) == TOHOST) begin
        if (dmem_wdata == 32'd1)
          $display("PASS %s cycles=%0d instret=%0d CPI=%0.3f", hex, run_cycles, instret,
                   real'(run_cycles) / instret);
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
    cycles <= cycles + 1;
    if (rst_n) begin
      run_cycles <= run_cycles + 1;
      instret <= instret + int'(retire);
    end
    if (cycles >= MAX_CYCLES) begin
      $display("FAIL %s: no result in %0d cycles", hex, MAX_CYCLES);
      $finish;
    end
  end

  initial begin
    if (!$value$plusargs("hex=%s", hex)) $fatal(1, "usage: +hex=<file>");
    for (int i = 0; i < WORDS; i++) mem[i] = 32'h0;
    $readmemh(hex, mem);
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
  end
endmodule
