// Set-associative, write-back, write-allocate data cache with LRU replacement.
// - Lookup: the tag and data arrays are synchronous block RAM read with the
//   address from EX, so in MEM their outputs belong to the access and a hit costs
//   no cycle.
// - Miss: `stall` freezes the pipeline while the cache writes back a dirty victim
//   (one word per cycle), requests the line, writes its words as they return and
//   reads the arrays again. The access then hits like any other.
// - I/O: addresses below 0x8000_0000 bypass the cache. A store there is a posted
//   word write to memory with no stall; the core has no I/O loads.
// Parameters: 2^INDEX_BITS sets, WAYS ways, 2^OFFSET_BITS-byte lines (at least 8).
module dcache #(
    parameter int INDEX_BITS = 5,
    parameter int WAYS = 2,
    parameter int OFFSET_BITS = 4
) (
    input  logic        clk,
    input  logic        rst_n,
    // EX: the address of the instruction that enters MEM next cycle
    input  logic [31:2] ex_addr,
    // MEM: the access
    input  logic        read,
    input  logic        write,
    input  logic [31:0] addr,
    input  logic [31:0] wdata,       // store data on its byte lanes
    input  logic [3:0]  wstrb,
    output logic [31:0] rdata,       // the word at addr
    output logic        stall,       // hold the pipeline: the access is not done
    // Memory (docs/interface.md)
    output logic        mem_req,     // one-cycle request for the line at mem_addr
    output logic [31:0] mem_addr,
    input  logic        mem_rvalid,  // one word of the line, first word first
    input  logic [31:0] mem_rdata,
    output logic [3:0]  mem_wstrb,   // nonzero: write mem_wdata to the word at mem_addr
    output logic [31:0] mem_wdata
);
  localparam int SETS = 1 << INDEX_BITS;
  localparam int WORD_BITS = OFFSET_BITS - 2;
  localparam int LINE_WORDS = 1 << WORD_BITS;
  localparam int TAG_BITS = 32 - INDEX_BITS - OFFSET_BITS;
  localparam int WAY_BITS = WAYS > 1 ? $clog2(WAYS) : 1;

  typedef enum logic [2:0] {IDLE, WRITEBACK, REQUEST, FILL, REREAD} state_t;
  state_t state;

  // ---------------------------------------------------------------- lookup
  logic [INDEX_BITS-1:0] set;
  logic [TAG_BITS-1:0] tag;
  logic [WORD_BITS-1:0] word;
  assign set = addr[OFFSET_BITS+:INDEX_BITS];
  assign tag = addr[31-:TAG_BITS];
  assign word = addr[2+:WORD_BITS];

  logic [WAYS-1:0] valid[SETS];
  logic [WAYS-1:0] dirty[SETS];
  // LRU rank per way: 0 most recently used, WAYS-1 least. Each set's ranks are
  // always a permutation of 0..WAYS-1.
  logic [WAY_BITS-1:0] age[SETS][WAYS];

  logic [TAG_BITS-1:0] tag_q[WAYS];  // array outputs, one per way
  logic [31:0] data_q[WAYS];

  logic cached, lookup, hit, miss;
  logic [WAYS-1:0] way_hit;
  logic [WAY_BITS-1:0] hit_way;

  assign cached = addr[31];
  assign lookup = state == IDLE && (read || write) && cached;

  always_comb begin
    hit_way = '0;
    for (int w = 0; w < WAYS; w++) begin
      way_hit[w] = valid[set][w] && tag_q[w] == tag;
      if (way_hit[w]) hit_way = WAY_BITS'(w);
    end
  end
  assign hit = |way_hit;
  assign miss = lookup && !hit;
  assign stall = state != IDLE || miss;

  // Victim: the first invalid way, else the least recently used.
  logic [WAY_BITS-1:0] victim_c, victim;
  always_comb begin
    victim_c = '0;
    for (int w = WAYS - 1; w >= 0; w--) if (age[set][w] == WAY_BITS'(WAYS - 1)) victim_c = WAY_BITS'(w);
    for (int w = WAYS - 1; w >= 0; w--) if (!valid[set][w]) victim_c = WAY_BITS'(w);
  end

  // A store that hits writes its word at the clock edge where the next
  // instruction reads the arrays, so that read misses the new bytes. If the next
  // access is to the same word, keep the store to merge into its read data.
  logic bypass;
  logic [31:0] bypass_data;
  logic [3:0] bypass_strb;

  always_comb begin
    rdata = data_q[hit_way];
    for (int b = 0; b < 4; b++)
      if (bypass && bypass_strb[b]) rdata[8*b+:8] = bypass_data[8*b+:8];
  end

  // ---------------------------------------------------------------- arrays
  logic [WORD_BITS:0] count;  // words written back or filled so far
  logic [TAG_BITS-1:0] victim_tag;
  logic [INDEX_BITS-1:0] read_set;
  logic [WORD_BITS-1:0] read_word;

  // Read for EX's access, except while stalled: then for MEM's access, or for
  // the next victim word during a writeback.
  always_comb begin
    read_set = stall ? set : ex_addr[OFFSET_BITS+:INDEX_BITS];
    read_word = stall ? word : ex_addr[2+:WORD_BITS];
    if (state == WRITEBACK) read_word = count[WORD_BITS-1:0];
  end

  logic store_hit, fill_word;
  assign store_hit = lookup && hit && write;
  assign fill_word = state == FILL && mem_rvalid;

  // Quartus parses only the SystemVerilog-2005 form of a generate loop.
  genvar way;
  generate
    for (way = 0; way < WAYS; way = way + 1) begin : g_way
      logic [TAG_BITS-1:0] tags[SETS];
      logic [31:0] words[SETS * LINE_WORDS];  // word {set, offset}
      logic we;
      logic [3:0] be;
      logic [INDEX_BITS+WORD_BITS-1:0] waddr;
      logic [31:0] wd;

      assign we = (store_hit && hit_way == WAY_BITS'(way)) || (fill_word && victim == WAY_BITS'(way));
      assign be = fill_word ? 4'b1111 : wstrb;
      assign waddr = {set, fill_word ? count[WORD_BITS-1:0] : word};
      assign wd = fill_word ? mem_rdata : wdata;

      always_ff @(posedge clk) begin
        tag_q[way] <= tags[read_set];
        data_q[way] <= words[{read_set, read_word}];
        if (state == REQUEST && victim == WAY_BITS'(way)) tags[set] <= tag;
        for (int b = 0; b < 4; b++) if (we && be[b]) words[waddr][8*b+:8] <= wd[8*b+:8];
      end
    end
  endgenerate

  // ---------------------------------------------------------------- memory
  // Writeback: word k is read in cycle k and written in cycle k+1.
  always_comb begin
    mem_req = state == REQUEST;
    mem_addr = {tag, set, {OFFSET_BITS{1'b0}}};
    mem_wstrb = 4'b0;
    mem_wdata = data_q[victim];
    if (state == WRITEBACK && count != 0) begin
      mem_addr = {victim_tag, set, WORD_BITS'(count - 1'b1), 2'b00};
      mem_wstrb = 4'b1111;
    end else if (state == IDLE && write && !cached) begin
      mem_addr = addr;
      mem_wstrb = wstrb;
      mem_wdata = wdata;
    end
  end

  // ---------------------------------------------------------------- control
  logic replay;  // MEM's access already counted its miss

  // One-cycle events, counted by the testbench: every cached access in program
  // order, and whether it hit, missed or evicted a dirty line.
  /* verilator lint_off UNUSEDSIGNAL */
  logic ev_access, ev_hit, ev_miss, ev_writeback;
  /* verilator lint_on UNUSEDSIGNAL */

  assign ev_access = lookup && !replay;
  assign ev_hit = lookup && hit && !replay;
  assign ev_miss = miss;
  assign ev_writeback = miss && valid[set][victim_c] && dirty[set][victim_c];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= IDLE;
      victim <= '0;
      victim_tag <= '0;
      count <= '0;
      replay <= 1'b0;
      bypass <= 1'b0;
      bypass_data <= '0;
      bypass_strb <= '0;
      for (int s = 0; s < SETS; s++) begin
        valid[s] <= '0;
        dirty[s] <= '0;
        for (int w = 0; w < WAYS; w++) age[s][w] <= WAY_BITS'(w);
      end
    end else begin
      bypass <= store_hit && ex_addr[31:2] == addr[31:2];
      bypass_data <= wdata;
      bypass_strb <= wstrb;
      case (state)
        IDLE: begin
          replay <= 1'b0;
          if (lookup && hit) begin
            if (write) dirty[set][hit_way] <= 1'b1;
            for (int w = 0; w < WAYS; w++)
              if (WAY_BITS'(w) == hit_way) age[set][w] <= '0;
              else if (age[set][w] < age[set][hit_way]) age[set][w] <= age[set][w] + 1'b1;
          end
          if (miss) begin
            victim <= victim_c;
            victim_tag <= tag_q[victim_c];
            count <= '0;
            state <= ev_writeback ? WRITEBACK : REQUEST;
          end
        end
        WRITEBACK: begin
          count <= count + 1'b1;
          if (count == (WORD_BITS + 1)'(LINE_WORDS)) state <= REQUEST;
        end
        REQUEST: begin
          valid[set][victim] <= 1'b0;  // until every word is in
          count <= '0;
          state <= FILL;
        end
        FILL:
        if (mem_rvalid) begin
          count <= count + 1'b1;
          if (count == (WORD_BITS + 1)'(LINE_WORDS - 1)) begin
            valid[set][victim] <= 1'b1;
            dirty[set][victim] <= 1'b0;
            state <= REREAD;
          end
        end
        REREAD: begin
          replay <= 1'b1;
          state <= IDLE;
        end
        default: state <= IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  always @(posedge clk)
    if (rst_n) begin
      assert (!(state == IDLE && read && !cached));  // no I/O loads
      assert (!(miss && replay));  // a replayed access hits
    end
`endif
endmodule
