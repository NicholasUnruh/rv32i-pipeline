// Branch target buffer with a 2-bit saturating counter per entry, direct-mapped
// on the PC. Fetch looks up its PC: a hit whose counter is 2 or 3 predicts taken
// to the stored target. EX updates the entry of every branch and jump it resolves.
module btb #(
    parameter int INDEX_BITS = 6  // 64 entries
) (
    input  logic        clk,
    input  logic        rst_n,
    // Fetch: prediction for lookup_pc
    input  logic [31:2] lookup_pc,  // instructions are word-aligned
    output logic        predict_taken,
    output logic [31:0] predict_target,
    // EX: outcome of a resolved branch or jump
    input  logic        update,
    input  logic [31:2] update_pc,
    input  logic        update_taken,
    input  logic [31:0] update_target
);
  localparam int ENTRIES = 1 << INDEX_BITS;
  localparam int TAG_BITS = 30 - INDEX_BITS;

  logic [ENTRIES-1:0] valid;
  logic [TAG_BITS-1:0] tags[ENTRIES];
  logic [31:0] targets[ENTRIES];
  logic [1:0] counters[ENTRIES];  // 0, 1: not taken; 2, 3: taken

  logic [INDEX_BITS-1:0] lookup_index, update_index;
  logic [TAG_BITS-1:0] lookup_tag, update_tag;
  logic update_hit;
  logic [1:0] counter;

  assign lookup_index = lookup_pc[INDEX_BITS+1:2];
  assign lookup_tag = lookup_pc[31:INDEX_BITS+2];
  assign update_index = update_pc[INDEX_BITS+1:2];
  assign update_tag = update_pc[31:INDEX_BITS+2];

  assign predict_taken = valid[lookup_index] && tags[lookup_index] == lookup_tag
      && counters[lookup_index][1];
  assign predict_target = targets[lookup_index];

  assign update_hit = valid[update_index] && tags[update_index] == update_tag;
  assign counter = counters[update_index];

  // A hit moves the counter one step toward the outcome. A taken miss takes the
  // entry at weakly not-taken, so a branch must be taken twice before it is
  // predicted taken: one-off taken branches and two-trip loops then cost no extra
  // misprediction. A not-taken miss leaves the BTB alone.
  always_ff @(posedge clk) begin
    if (update && update_hit) begin
      if (update_taken) begin
        counters[update_index] <= counter == 2'd3 ? 2'd3 : counter + 2'd1;
        targets[update_index] <= update_target;
      end else begin
        counters[update_index] <= counter == 2'd0 ? 2'd0 : counter - 2'd1;
      end
    end else if (update && update_taken) begin
      tags[update_index] <= update_tag;
      targets[update_index] <= update_target;
      counters[update_index] <= 2'd1;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) valid <= '0;
    else if (update && update_taken) valid[update_index] <= 1'b1;
  end
endmodule
