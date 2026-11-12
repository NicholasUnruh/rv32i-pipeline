// Branch target buffer with a 2-bit saturating counter per entry, direct-mapped
// on the PC. Fetch looks up its PC: a hit whose counter is 2 or 3 predicts taken
// to the stored target. EX updates the entry of every branch and jump it resolves.
// Tags and targets are synchronous block RAM read with the next PC, like the
// instruction cache; valid bits and counters are registers.
module btb #(
    parameter int INDEX_BITS = 6  // 64 entries
) (
    input  logic        clk,
    input  logic        rst_n,
    // Fetch: prediction for pc
    input  logic [INDEX_BITS+1:2] next_pc,  // read address: index of the next PC
    input  logic [31:2] pc,
    output logic        lookup_hit,  // pc has an entry (travels with the instruction)
    output logic        predict_taken,
    output logic [31:0] predict_target,
    // EX: outcome of a resolved branch or jump
    input  logic        update,
    input  logic [31:2] update_pc,
    input  logic        update_hit,  // lookup_hit from when this instruction was fetched;
                                     // if the entry changed since, only accuracy suffers
    input  logic        update_taken,
    input  logic [31:0] update_target
);
  localparam int ENTRIES = 1 << INDEX_BITS;
  localparam int TAG_BITS = 30 - INDEX_BITS;

  logic [ENTRIES-1:0] valid;
  logic [1:0] counters[ENTRIES];  // 0, 1: not taken; 2, 3: taken
  logic [TAG_BITS-1:0] tags[ENTRIES];
  logic [31:0] targets[ENTRIES];
  logic [TAG_BITS-1:0] tag_q;  // tags[] at pc's index

  logic [INDEX_BITS-1:0] index, update_index;
  logic [1:0] counter;

  assign index = pc[INDEX_BITS+1:2];
  assign update_index = update_pc[INDEX_BITS+1:2];

  always_ff @(posedge clk) begin
    tag_q <= tags[next_pc];
    predict_target <= targets[next_pc];
  end

  assign lookup_hit = valid[index] && tag_q == pc[31:INDEX_BITS+2];
  assign predict_taken = lookup_hit && counters[index][1];
  assign counter = counters[update_index];

  // A hit moves the counter one step toward the outcome. A taken miss takes the
  // entry at weakly not-taken, so a branch must be taken twice before it is
  // predicted taken: one-off taken branches and two-trip loops then cost no extra
  // misprediction. A not-taken miss leaves the BTB alone.
  always_ff @(posedge clk) begin
    if (update && update_hit) begin
      if (update_taken) targets[update_index] <= update_target;
    end else if (update && update_taken) begin
      tags[update_index] <= update_pc[31:INDEX_BITS+2];
      targets[update_index] <= update_target;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid <= '0;
      for (int i = 0; i < ENTRIES; i++) counters[i] <= 2'd0;
    end else if (update && update_hit) begin
      if (update_taken) counters[update_index] <= counter == 2'd3 ? 2'd3 : counter + 2'd1;
      else counters[update_index] <= counter == 2'd0 ? 2'd0 : counter - 2'd1;
    end else if (update && update_taken) begin
      valid[update_index] <= 1'b1;
      counters[update_index] <= 2'd1;
    end
  end
endmodule
