// Set-associative instruction cache: 2^INDEX_BITS sets of WAYS ways of 16-byte
// lines, read-only, BRRIP replacement (docs/10-icache.md). The default, 128 sets of
// 8 ways (16 KB), was chosen with cache-sim on Embench traces.
// The tag and data arrays are synchronous block RAM: they are read with the next
// PC, so their outputs hold the entry for `pc` one clock later and a hit costs no
// cycle. On a miss the cache requests the line from memory, which returns its
// four words in order on later cycles (see docs/interface.md).
//
// Replacement follows cache-sim's BRRIP exactly: each line has a 2-bit re-reference
// prediction value (RRPV). A hit sets it to 0. A miss takes the first invalid way,
// else the first way with the highest RRPV after aging the whole set until one
// reaches 3. The new line starts at 3, except every 32nd fill, which starts at 2.
module icache #(
    parameter int INDEX_BITS = 7,  // 128 sets...
    parameter int WAYS = 8         // ...of this many ways
) (
    input  logic        clk,
    input  logic        rst_n,
    // Fetch
    input  logic [INDEX_BITS+3:2] next_pc,  // read address: index and word of the next PC
    input  logic [31:4] pc,                 // line address being fetched this cycle
    output logic        hit,
    output logic [31:0] instr,
    // Memory
    output logic        mem_req,     // one-cycle request for the line at mem_addr
    output logic [31:0] mem_addr,
    input  logic        mem_rvalid,  // one word of the line, first word first
    input  logic [31:0] mem_rdata
);
  localparam int SETS = 1 << INDEX_BITS;
  localparam int TAG_BITS = 28 - INDEX_BITS;
  localparam int WAY_BITS = WAYS > 1 ? $clog2(WAYS) : 1;

  // valid is one flat vector of registers, way w of set s at s * WAYS + w, so a
  // single assignment resets it. The RRPVs are block RAM, one row per set: they are
  // read only when every way of the set is valid, and a line's RRPV is written when
  // it is filled, so they need no reset.
  logic [SETS*WAYS-1:0] valid;
  logic [WAYS-1:0] set_valid;  // valid bits of pc's set
  logic [2*WAYS-1:0] rrpv[SETS];  // way w at [2*w+:2]
  logic [2*WAYS-1:0] rrpv_q, set_rrpv, rrpv_next;  // pc's set: read, current, written
  logic rrpv_we;
  logic [TAG_BITS-1:0] tag_q[WAYS];  // array outputs, one per way, for pc's set
  logic [31:0] instr_q[WAYS];

  logic [INDEX_BITS-1:0] index;
  logic [TAG_BITS-1:0] tag;
  logic [WAYS-1:0] way_hit;
  logic [WAY_BITS-1:0] hit_way;

  assign index = pc[INDEX_BITS+3:4];
  assign tag = pc[31:INDEX_BITS+4];
  assign set_valid = valid[index*WAYS+:WAYS];

  always_comb begin
    hit_way = '0;
    for (int w = 0; w < WAYS; w++) begin
      way_hit[w] = set_valid[w] && tag_q[w] == tag;
      if (way_hit[w]) hit_way = WAY_BITS'(w);
    end
  end

  assign hit = |way_hit;
  assign instr = instr_q[hit_way];

  // Victim: the first invalid way, else the first way with the highest RRPV.
  logic [WAY_BITS-1:0] victim;
  logic [1:0] max_rrpv;

  always_comb begin
    max_rrpv = 2'd0;
    victim = '0;
    for (int w = WAYS - 1; w >= 0; w--)
      if (set_rrpv[2*w+:2] >= max_rrpv) begin
        max_rrpv = set_rrpv[2*w+:2];
        victim = WAY_BITS'(w);
      end
    for (int w = WAYS - 1; w >= 0; w--)
      if (!set_valid[w]) victim = WAY_BITS'(w);
  end

  // Refill: request the missing line, write each returning word, then mark the
  // line valid one cycle after the last write, once a read can see that word.
  logic filling, finishing;
  logic [INDEX_BITS-1:0] fill_index;
  logic [WAY_BITS-1:0] fill_way;
  logic [1:0] fill_word;
  logic [4:0] fills;  // BRRIP: every 32nd fill is inserted at RRPV 2
  // The fetch that missed hits once its line is in; that hit is the same access,
  // not a re-reference, so it must not promote the line. `missed` holds until a
  // lookup of another line hits or misses.
  logic missed;
  logic [31:4] missed_line;

  assign mem_req = !filling && !hit;
  assign mem_addr = {pc, 4'b0};

  // RRPV row of pc's set. The array is read with the next PC like the tags; a write
  // on the same edge is missed by that read, so the written row is bypassed.
  logic rrpv_wrote;
  logic [INDEX_BITS-1:0] rrpv_wrote_set;
  logic [2*WAYS-1:0] rrpv_wrote_row;

  assign set_rrpv = rrpv_wrote && rrpv_wrote_set == index ? rrpv_wrote_row : rrpv_q;

  // A miss inserts the new line and ages a full set until its victim reaches 3; a
  // set with an invalid way is not aged. A hit promotes its line to 0.
  always_comb begin
    rrpv_next = set_rrpv;
    rrpv_we = 1'b0;
    if (rst_n && mem_req) begin
      rrpv_we = 1'b1;
      for (int w = 0; w < WAYS; w++)
        if (WAY_BITS'(w) == victim) rrpv_next[2*w+:2] = fills == 5'd31 ? 2'd2 : 2'd3;
        else if (&set_valid) rrpv_next[2*w+:2] = set_rrpv[2*w+:2] + (2'd3 - max_rrpv);
    end else if (rst_n && hit && !(missed && pc == missed_line)) begin
      rrpv_we = 1'b1;
      for (int w = 0; w < WAYS; w++) if (WAY_BITS'(w) == hit_way) rrpv_next[2*w+:2] = 2'd0;
    end
  end

  always_ff @(posedge clk) begin
    rrpv_q <= rrpv[next_pc[INDEX_BITS+3:4]];
    if (rrpv_we) rrpv[index] <= rrpv_next;
    rrpv_wrote_set <= index;
    rrpv_wrote_row <= rrpv_next;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) rrpv_wrote <= 1'b0;
    else rrpv_wrote <= rrpv_we;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      filling <= 1'b0;
      finishing <= 1'b0;
      fill_index <= '0;
      fill_way <= '0;
      fill_word <= '0;
      fills <= '0;
      missed <= 1'b0;
      missed_line <= '0;
      valid <= '0;
    end else if (mem_req) begin
      // The line is invalid until all four words are in.
      filling <= 1'b1;
      fill_index <= index;
      fill_way <= victim;
      fill_word <= '0;
      fills <= fills + 5'd1;
      missed <= 1'b1;
      missed_line <= pc;
      valid[index*WAYS+32'(victim)] <= 1'b0;
    end else begin
      if (hit && pc != missed_line) missed <= 1'b0;
      if (finishing) begin
        filling <= 1'b0;
        finishing <= 1'b0;
        valid[fill_index*WAYS+32'(fill_way)] <= 1'b1;
      end else if (filling && mem_rvalid) begin
        fill_word <= fill_word + 2'd1;
        finishing <= fill_word == 2'd3;
      end
    end
  end

  // Quartus parses only the SystemVerilog-2005 form of a generate loop.
  genvar way;
  generate
    for (way = 0; way < WAYS; way = way + 1) begin : g_way
      logic [TAG_BITS-1:0] tags[SETS];
      logic [31:0] words[SETS * 4];  // word {index, offset}

      always_ff @(posedge clk) begin
        tag_q[way] <= tags[next_pc[INDEX_BITS+3:4]];
        instr_q[way] <= words[next_pc];
      end

      always_ff @(posedge clk) begin
        if (mem_req && victim == WAY_BITS'(way)) tags[index] <= tag;
        if (filling && mem_rvalid && fill_way == WAY_BITS'(way))
          words[{fill_index, fill_word}] <= mem_rdata;
      end
    end
  endgenerate
endmodule
