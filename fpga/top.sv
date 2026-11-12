// DE1-SoC top level: the core runs the program in block RAM (quartus/program.hex,
// the C benchmark) from KEY[0] release until it stores to tohost.
// - LEDR[0] pass, LEDR[1] fail, LEDR[9] running.
// - HEX5..HEX0: cycles in hex; hold KEY[1] for instructions retired.
// - KEY[0] (active low) resets the core and the counters.
module top (
    input  logic       CLOCK_50,
    input  logic [1:0] KEY,
    output logic [9:0] LEDR,
    output logic [6:0] HEX0,
    output logic [6:0] HEX1,
    output logic [6:0] HEX2,
    output logic [6:0] HEX3,
    output logic [6:0] HEX4,
    output logic [6:0] HEX5
);
  localparam logic [31:0] TOHOST = 32'h8000_FFF0;

  logic clk;
  assign clk = CLOCK_50;

  // Reset: asserts at once, releases synchronously to clk.
  logic [1:0] reset_sync;
  logic rst_n;

  always_ff @(posedge clk or negedge KEY[0]) begin
    if (!KEY[0]) reset_sync <= 2'b00;
    else reset_sync <= {reset_sync[0], 1'b1};
  end
  assign rst_n = reset_sync[1];

  logic imem_req, imem_rvalid, retire;
  logic [31:0] imem_rdata, dmem_wdata, dmem_rdata;
  // 64 KB of memory decodes only address bits [15:2]; the board does not count fetches.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] imem_addr, dmem_addr;
  logic fetch;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [3:0] dmem_wstrb;

  core cpu (
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

  // Line fill: read the four words of the requested line on four cycles. Each
  // word arrives the cycle after its address, so the first comes 2 cycles after
  // the request.
  logic [13:0] fill_word;
  logic [2:0] fill_left;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fill_word <= '0;
      fill_left <= '0;
      imem_rvalid <= 1'b0;
    end else begin
      imem_rvalid <= fill_left != 3'd0;
      if (imem_req) begin
        fill_word <= imem_addr[15:2];
        fill_left <= 3'd4;
      end else if (fill_left != 3'd0) begin
        fill_word <= fill_word + 14'd1;
        fill_left <= fill_left - 3'd1;
      end
    end
  end

  ram memory (
      .clk(clk),
      .a_addr(fill_word),
      .a_rdata(imem_rdata),
      .b_addr(dmem_addr[15:2]),
      .b_wstrb(dmem_wstrb),
      .b_wdata(dmem_wdata),
      .b_rdata(dmem_rdata)
  );

  // Result and counters, frozen at the tohost store.
  logic done, passed;
  logic [23:0] cycles, instret;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      done <= 1'b0;
      passed <= 1'b0;
      cycles <= '0;
      instret <= '0;
    end else if (!done) begin
      cycles <= cycles + 24'd1;
      instret <= instret + {23'd0, retire};
      if (dmem_wstrb != 4'b0 && {dmem_addr[31:2], 2'b00} == TOHOST) begin
        done <= 1'b1;
        passed <= dmem_wdata == 32'd1;
      end
    end
  end

  assign LEDR = {!done, 7'b0, done && !passed, done && passed};

  logic [23:0] display;
  assign display = KEY[1] ? cycles : instret;  // KEY[1] reads 0 while pressed

  seven_segment h0 (.value(display[3:0]), .blank(1'b0), .segments_n(HEX0));
  seven_segment h1 (.value(display[7:4]), .blank(1'b0), .segments_n(HEX1));
  seven_segment h2 (.value(display[11:8]), .blank(1'b0), .segments_n(HEX2));
  seven_segment h3 (.value(display[15:12]), .blank(1'b0), .segments_n(HEX3));
  seven_segment h4 (.value(display[19:16]), .blank(1'b0), .segments_n(HEX4));
  seven_segment h5 (.value(display[23:20]), .blank(1'b0), .segments_n(HEX5));
endmodule
