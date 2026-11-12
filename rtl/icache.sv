// Direct-mapped instruction cache: 64 lines of 16 bytes (1 KB), read-only.
// A lookup hits in the same cycle. On a miss the cache requests the line from
// memory, which returns its four words in order on later cycles (see
// docs/interface.md); the line becomes valid after the fourth.
module icache #(
    parameter int INDEX_BITS = 6  // 64 lines
) (
    input  logic        clk,
    input  logic        rst_n,
    // Fetch
    input  logic [31:2] pc,
    output logic        hit,
    output logic [31:0] instr,
    // Memory
    output logic        mem_req,     // one-cycle request for the line at mem_addr
    output logic [31:0] mem_addr,
    input  logic        mem_rvalid,  // one word of the line, first word first
    input  logic [31:0] mem_rdata
);
  localparam int LINES = 1 << INDEX_BITS;
  localparam int TAG_BITS = 28 - INDEX_BITS;

  logic [LINES-1:0] valid;
  logic [TAG_BITS-1:0] tags[LINES];
  logic [31:0] words[LINES * 4];  // word {index, offset}

  logic [INDEX_BITS-1:0] index;
  logic [TAG_BITS-1:0] tag;
  logic [1:0] offset;

  assign offset = pc[3:2];
  assign index = pc[INDEX_BITS+3:4];
  assign tag = pc[31:INDEX_BITS+4];

  assign hit = valid[index] && tags[index] == tag;
  assign instr = words[{index, offset}];

  // Refill: request the missing line, then write each returning word.
  logic filling;
  logic [INDEX_BITS-1:0] fill_index;
  logic [1:0] fill_word;

  assign mem_req = !filling && !hit;
  assign mem_addr = {pc[31:4], 4'b0};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      filling <= 1'b0;
      fill_index <= '0;
      fill_word <= '0;
      valid <= '0;
    end else if (mem_req) begin
      // The line is invalid until all four words are in.
      filling <= 1'b1;
      fill_index <= index;
      fill_word <= '0;
      valid[index] <= 1'b0;
    end else if (filling && mem_rvalid) begin
      fill_word <= fill_word + 2'd1;
      if (fill_word == 2'd3) begin
        filling <= 1'b0;
        valid[fill_index] <= 1'b1;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (mem_req) tags[index] <= tag;
    if (filling && mem_rvalid) words[{fill_index, fill_word}] <= mem_rdata;
  end
endmodule
