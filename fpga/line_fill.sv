// Line fill from block RAM: after a request, reads the line's words on
// consecutive cycles. Each word arrives the cycle after its address, so the first
// comes 2 cycles after the request, together with rvalid.
module line_fill #(
    parameter int LINE_WORDS = 4
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        req,
    input  logic [13:0] line_word,  // word address of the line's first word
    output logic [13:0] word,       // RAM read address
    output logic        rvalid
);
  logic [$clog2(LINE_WORDS):0] left;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      word <= '0;
      left <= '0;
      rvalid <= 1'b0;
    end else begin
      rvalid <= left != 0;
      if (req) begin
        word <= line_word;
        left <= ($clog2(LINE_WORDS) + 1)'(LINE_WORDS);
      end else if (left != 0) begin
        word <= word + 14'd1;
        left <= left - 1'b1;
      end
    end
  end
endmodule
