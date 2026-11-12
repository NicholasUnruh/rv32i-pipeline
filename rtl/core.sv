// Five-stage pipelined RV32I core: IF, ID, EX, MEM, WB.
// - Forwarding: EX takes operands from the instructions in MEM and WB.
// - Load-use: an instruction that needs a load's result in EX waits one cycle in ID.
// - Control: IF predicts with a BTB; branches and jumps resolve in EX, and a
//   misprediction flushes IF and ID.
// - Fetch: IF reads an instruction cache; a miss sends bubbles until the line is in.
// - Data: MEM reads and writes a data cache; a miss freezes every stage, WB
//   included, until the line is in.
// Ports and the memory protocol are in docs/interface.md.
module core #(
    parameter int DCACHE_INDEX_BITS = 5,   // data cache: 2^bits sets...
    parameter int DCACHE_WAYS = 2,         // ...of this many ways...
    parameter int DCACHE_OFFSET_BITS = 4   // ...of 2^bits-byte lines
) (
    input  logic        clk,
    input  logic        rst_n,
    output logic        imem_req,
    output logic [31:0] imem_addr,
    input  logic        imem_rvalid,
    input  logic [31:0] imem_rdata,
    output logic        dmem_req,
    output logic [31:0] dmem_addr,
    input  logic        dmem_rvalid,
    input  logic [31:0] dmem_rdata,
    output logic [31:0] dmem_wdata,
    output logic [3:0]  dmem_wstrb,
    output logic        fetch,       // IF passed an instruction to ID this cycle
    output logic        retire       // an instruction completed this cycle
);
  localparam logic [31:0] RESET_PC = 32'h8000_0000;

  // Pipeline registers. A bubble has every field zero, so it writes nothing.
  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] instr;
    logic        pred_hit;     // IF's BTB lookup, used to update the BTB in EX
    logic        pred_taken;   // IF's prediction, checked in EX
    logic [31:0] pred_target;
  } if_id_t;

  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic        pred_hit, pred_taken;
    logic [31:0] pred_target;
    logic [4:0]  rs1, rs2, rd;
    logic        uses_rs1, uses_rs2;
    logic [31:0] rs1_val, rs2_val, imm;
    logic [3:0]  alu_op;
    logic        alu_a_pc, alu_a_zero, alu_b_imm;
    logic        reg_write, mem_read, mem_write, branch, jal, jalr, illegal;
    logic [2:0]  funct3;
  } id_ex_t;

  typedef struct packed {
    logic        valid;
    logic [4:0]  rd;
    logic        reg_write, mem_read, mem_write;
    logic [2:0]  funct3;
    logic [31:0] result;     // ALU result (the address for memory), or PC+4 for jumps
    logic [31:0] store_data; // on its byte lanes
    logic [3:0]  store_strb;
  } ex_mem_t;

  typedef struct packed {
    logic        valid;
    logic [4:0]  rd;
    logic        reg_write;
    logic [31:0] value;      // what the instruction writes to rd
  } mem_wb_t;

  if_id_t if_id, if_id_next;
  id_ex_t id_ex, id_ex_next;
  ex_mem_t ex_mem, ex_mem_next;
  mem_wb_t mem_wb, mem_wb_next;

  logic stall;     // load-use hazard: hold IF and ID, send a bubble to EX
  logic redirect;  // misprediction in EX: flush IF and ID
  logic dstall;    // data cache miss in MEM: hold every stage
  logic [31:0] redirect_pc;

  // ---------------------------------------------------------------- IF
  // The cache and BTB arrays are synchronous, so they are read with next_pc and
  // answer for pc in the following cycle.
  logic [31:0] pc, next_pc;
  logic pred_hit, pred_taken;
  logic [31:0] pred_target;
  logic cache_hit;
  logic [31:0] cache_instr;

  icache cache (
      .clk(clk),
      .rst_n(rst_n),
      .next_pc(next_pc[9:2]),
      .pc(pc[31:4]),
      .hit(cache_hit),
      .instr(cache_instr),
      .mem_req(imem_req),
      .mem_addr(imem_addr),
      .mem_rvalid(imem_rvalid),
      .mem_rdata(imem_rdata)
  );

  assign fetch = cache_hit && !stall && !redirect && !dstall;

  always_comb begin
    if_id_next.valid = cache_hit;  // a miss sends a bubble
    if_id_next.pc = pc;
    if_id_next.instr = cache_instr;
    if_id_next.pred_hit = pred_hit;
    if_id_next.pred_taken = pred_taken;
    if_id_next.pred_target = pred_target;
  end

  always_comb begin
    if (!rst_n) next_pc = RESET_PC;
    else if (redirect) next_pc = redirect_pc;
    else if (dstall || stall || !cache_hit) next_pc = pc;
    else if (pred_taken) next_pc = pred_target;
    else next_pc = pc + 32'd4;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) pc <= RESET_PC;
    else pc <= next_pc;
  end

  // ---------------------------------------------------------------- ID
  logic [4:0] rs1, rs2, rd;
  logic uses_rs1, uses_rs2;
  logic [31:0] imm, rs1_val, rs2_val;
  logic [3:0] alu_op;
  logic alu_a_pc, alu_a_zero, alu_b_imm;
  logic reg_write, mem_read, mem_write, branch, jal, jalr, illegal;
  logic [2:0] funct3;

  decoder dec (
      .instr(if_id.instr),
      .rs1(rs1),
      .rs2(rs2),
      .rd(rd),
      .uses_rs1(uses_rs1),
      .uses_rs2(uses_rs2),
      .imm(imm),
      .alu_op(alu_op),
      .alu_a_pc(alu_a_pc),
      .alu_a_zero(alu_a_zero),
      .alu_b_imm(alu_b_imm),
      .reg_write(reg_write),
      .mem_read(mem_read),
      .mem_write(mem_write),
      .branch(branch),
      .jal(jal),
      .jalr(jalr),
      .funct3(funct3),
      .illegal(illegal)
  );

  regfile rf (
      .clk(clk),
      .raddr1(rs1),
      .raddr2(rs2),
      .rdata1(rs1_val),
      .rdata2(rs2_val),
      .we(mem_wb.reg_write),
      .waddr(mem_wb.rd),
      .wdata(mem_wb.value)
  );

  // A load's data exists only at the end of MEM, too late for the next
  // instruction's EX, so that instruction waits in ID for one cycle.
  assign stall = if_id.valid && id_ex.mem_read && id_ex.rd != 5'd0
      && ((uses_rs1 && rs1 == id_ex.rd) || (uses_rs2 && rs2 == id_ex.rd));

  always_comb begin
    id_ex_next = '0;
    if (if_id.valid && !stall) begin
      id_ex_next.valid = 1'b1;
      id_ex_next.pc = if_id.pc;
      id_ex_next.pred_hit = if_id.pred_hit;
      id_ex_next.pred_taken = if_id.pred_taken;
      id_ex_next.pred_target = if_id.pred_target;
      id_ex_next.rs1 = rs1;
      id_ex_next.rs2 = rs2;
      id_ex_next.rd = rd;
      id_ex_next.uses_rs1 = uses_rs1;
      id_ex_next.uses_rs2 = uses_rs2;
      id_ex_next.rs1_val = rs1_val;
      id_ex_next.rs2_val = rs2_val;
      id_ex_next.imm = imm;
      id_ex_next.alu_op = alu_op;
      id_ex_next.alu_a_pc = alu_a_pc;
      id_ex_next.alu_a_zero = alu_a_zero;
      id_ex_next.alu_b_imm = alu_b_imm;
      id_ex_next.reg_write = reg_write && rd != 5'd0;
      id_ex_next.mem_read = mem_read;
      id_ex_next.mem_write = mem_write;
      id_ex_next.branch = branch;
      id_ex_next.jal = jal;
      id_ex_next.jalr = jalr;
      id_ex_next.illegal = illegal;
      id_ex_next.funct3 = funct3;
    end
  end

  // ---------------------------------------------------------------- EX
  logic a_from_mem, a_from_wb, b_from_mem, b_from_wb;
  logic [31:0] fwd_a, fwd_b, alu_a, alu_b, alu_y;
  logic is_control, taken;
  logic [31:0] target, pc_plus4;

  // Forwarding: take the youngest in-flight write to rs (MEM before WB), else the
  // value read in ID. reg_write is never set for rd = x0.
  assign a_from_mem = ex_mem.reg_write && ex_mem.rd == id_ex.rs1;
  assign a_from_wb = mem_wb.reg_write && mem_wb.rd == id_ex.rs1;
  assign b_from_mem = ex_mem.reg_write && ex_mem.rd == id_ex.rs2;
  assign b_from_wb = mem_wb.reg_write && mem_wb.rd == id_ex.rs2;

  assign fwd_a = a_from_mem ? ex_mem.result : a_from_wb ? mem_wb.value : id_ex.rs1_val;
  assign fwd_b = b_from_mem ? ex_mem.result : b_from_wb ? mem_wb.value : id_ex.rs2_val;

  assign alu_a = id_ex.alu_a_pc ? id_ex.pc : id_ex.alu_a_zero ? 32'b0 : fwd_a;
  assign alu_b = id_ex.alu_b_imm ? id_ex.imm : fwd_b;

  alu ex_alu (
      .op(id_ex.alu_op),
      .a(alu_a),
      .b(alu_b),
      .y(alu_y)
  );

  // Resolve control flow and check IF's guess: direction, and target when taken.
  // Any instruction can be mispredicted if the BTB says taken, so check them all.
  assign is_control = id_ex.branch || id_ex.jal || id_ex.jalr;
  assign taken = id_ex.jal || id_ex.jalr
      || (id_ex.branch && branch_taken(id_ex.funct3, fwd_a, fwd_b));
  assign target = id_ex.jalr ? (fwd_a + id_ex.imm) & ~32'd1 : id_ex.pc + id_ex.imm;
  assign pc_plus4 = id_ex.pc + 32'd4;
  assign redirect = id_ex.valid && !dstall && (taken != id_ex.pred_taken
                                               || (taken && target != id_ex.pred_target));
  assign redirect_pc = taken ? target : pc_plus4;

  btb predictor (
      .clk(clk),
      .rst_n(rst_n),
      .next_pc(next_pc[7:2]),
      .pc(pc[31:2]),
      .lookup_hit(pred_hit),
      .predict_taken(pred_taken),
      .predict_target(pred_target),
      .update(id_ex.valid && is_control && !dstall),
      .update_pc(id_ex.pc[31:2]),
      .update_hit(id_ex.pred_hit),
      .update_taken(taken),
      .update_target(target)
  );

  always_comb begin
    ex_mem_next.valid = id_ex.valid;
    ex_mem_next.rd = id_ex.rd;
    ex_mem_next.reg_write = id_ex.reg_write;
    ex_mem_next.mem_read = id_ex.mem_read;
    ex_mem_next.mem_write = id_ex.mem_write;
    ex_mem_next.funct3 = id_ex.funct3;
    ex_mem_next.result = id_ex.jal || id_ex.jalr ? pc_plus4 : alu_y;
    ex_mem_next.store_data = store_data(id_ex.funct3[1:0], fwd_b);
    ex_mem_next.store_strb = id_ex.mem_write ? store_strobe(id_ex.funct3[1:0], alu_y[1:0]) : 4'b0;
  end

  // ---------------------------------------------------------------- MEM
  // The cache arrays are synchronous: EX sends the address, and MEM gets the
  // word and the hit a clock later.
  logic [31:0] load_word;

  dcache #(
      .INDEX_BITS(DCACHE_INDEX_BITS),
      .WAYS(DCACHE_WAYS),
      .OFFSET_BITS(DCACHE_OFFSET_BITS)
  ) dc (
      .clk(clk),
      .rst_n(rst_n),
      .ex_addr(alu_y[31:2]),
      .read(ex_mem.mem_read),
      .write(ex_mem.mem_write),
      .addr(ex_mem.result),
      .wdata(ex_mem.store_data),
      .wstrb(ex_mem.store_strb),
      .rdata(load_word),
      .stall(dstall),
      .mem_req(dmem_req),
      .mem_addr(dmem_addr),
      .mem_rvalid(dmem_rvalid),
      .mem_rdata(dmem_rdata),
      .mem_wstrb(dmem_wstrb),
      .mem_wdata(dmem_wdata)
  );

  always_comb begin
    mem_wb_next.valid = ex_mem.valid;
    mem_wb_next.rd = ex_mem.rd;
    mem_wb_next.reg_write = ex_mem.reg_write;
    mem_wb_next.value = ex_mem.mem_read
        ? load_extend(ex_mem.funct3, ex_mem.result[1:0], load_word) : ex_mem.result;
  end

  // ---------------------------------------------------------------- WB
  // WB holds through a data miss so that EX can still forward from it; it writes
  // the same value each cycle but retires once.
  assign retire = mem_wb.valid && !dstall;

  // ---------------------------------------------------------------- registers
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      if_id <= '0;
      id_ex <= '0;
      ex_mem <= '0;
      mem_wb <= '0;
    end else if (!dstall) begin
      if (redirect) if_id <= '0;
      else if (!stall) if_id <= if_id_next;
      id_ex <= redirect ? '0 : id_ex_next;
      ex_mem <= ex_mem_next;
      mem_wb <= mem_wb_next;
    end
  end

  // ---------------------------------------------------------------- functions
  // Branch condition for funct3 beq, bne, blt, bge, bltu, bgeu.
  function automatic logic branch_taken(input logic [2:0] cond, input logic [31:0] x,
                                        input logic [31:0] y);
    case (cond)
      3'b000:  branch_taken = x == y;
      3'b001:  branch_taken = x != y;
      3'b100:  branch_taken = $signed(x) < $signed(y);
      3'b101:  branch_taken = $signed(x) >= $signed(y);
      3'b110:  branch_taken = x < y;
      3'b111:  branch_taken = x >= y;
      default: branch_taken = 1'b0;
    endcase
  endfunction

  // Stores put the low byte or halfword of the register on every lane it may use;
  // the strobes pick the lanes that are written.
  function automatic logic [31:0] store_data(input logic [1:0] size, input logic [31:0] value);
    case (size)
      2'b00:   store_data = {4{value[7:0]}};
      2'b01:   store_data = {2{value[15:0]}};
      default: store_data = value;
    endcase
  endfunction

  function automatic logic [3:0] store_strobe(input logic [1:0] size, input logic [1:0] offset);
    case (size)
      2'b00:   store_strobe = 4'b0001 << offset;
      2'b01:   store_strobe = offset[1] ? 4'b1100 : 4'b0011;
      default: store_strobe = 4'b1111;
    endcase
  endfunction

  // Loads pick their byte or halfword from the word and sign- or zero-extend it.
  function automatic logic [31:0] load_extend(input logic [2:0] width, input logic [1:0] offset,
                                              input logic [31:0] word);
    logic [7:0] b;
    logic [15:0] h;
    b = word[8*offset+:8];
    h = offset[1] ? word[31:16] : word[15:0];
    case (width)
      3'b000:  load_extend = {{24{b[7]}}, b};
      3'b001:  load_extend = {{16{h[15]}}, h};
      3'b100:  load_extend = {24'b0, b};
      3'b101:  load_extend = {16'b0, h};
      default: load_extend = word;
    endcase
  endfunction

`ifndef SYNTHESIS
  always @(posedge clk)
    if (rst_n && id_ex.valid) begin
      assert (!id_ex.illegal) else $error("illegal instruction at %h", id_ex.pc);
      // The load-use stall must keep a load in MEM from feeding EX.
      assert (!(ex_mem.mem_read
                && ((id_ex.uses_rs1 && a_from_mem) || (id_ex.uses_rs2 && b_from_mem))))
      else $error("load result needed in EX one cycle early at %h", id_ex.pc);
    end
`endif
endmodule
