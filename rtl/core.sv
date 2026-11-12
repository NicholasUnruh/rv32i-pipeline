// Five-stage pipelined RV32I core: IF, ID, EX, MEM, WB.
// - Forwarding: EX takes operands from the instructions in MEM and WB.
// - Load-use: an instruction that needs a load's result in EX waits one cycle in ID.
// - Control: branches and jumps resolve in EX; a taken one flushes IF and ID.
// Ports and the memory protocol are in docs/interface.md.
module core (
    input  logic        clk,
    input  logic        rst_n,
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata,
    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    output logic [3:0]  dmem_wstrb,
    input  logic [31:0] dmem_rdata,
    output logic        retire       // an instruction completed this cycle
);
  localparam logic [31:0] RESET_PC = 32'h8000_0000;

  // Pipeline registers. A bubble has every field zero, so it writes nothing.
  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] instr;
  } if_id_t;

  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
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
    logic [31:0] store_val;  // rs2 after forwarding
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
  logic redirect;  // taken branch or jump in EX: flush IF and ID
  logic [31:0] redirect_pc;

  // ---------------------------------------------------------------- IF
  logic [31:0] pc;

  assign imem_addr = pc;
  always_comb begin
    if_id_next.valid = 1'b1;
    if_id_next.pc = pc;
    if_id_next.instr = imem_rdata;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) pc <= RESET_PC;
    else if (redirect) pc <= redirect_pc;
    else if (!stall) pc <= pc + 32'd4;
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
  logic taken;

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

  assign taken = id_ex.branch && branch_taken(id_ex.funct3, fwd_a, fwd_b);
  assign redirect = taken || id_ex.jal || id_ex.jalr;
  assign redirect_pc = id_ex.jalr ? (fwd_a + id_ex.imm) & ~32'd1 : id_ex.pc + id_ex.imm;

  always_comb begin
    ex_mem_next.valid = id_ex.valid;
    ex_mem_next.rd = id_ex.rd;
    ex_mem_next.reg_write = id_ex.reg_write;
    ex_mem_next.mem_read = id_ex.mem_read;
    ex_mem_next.mem_write = id_ex.mem_write;
    ex_mem_next.funct3 = id_ex.funct3;
    ex_mem_next.result = id_ex.jal || id_ex.jalr ? id_ex.pc + 32'd4 : alu_y;
    ex_mem_next.store_val = fwd_b;
  end

  // ---------------------------------------------------------------- MEM
  assign dmem_addr = ex_mem.result;
  assign dmem_wdata = store_data(ex_mem.funct3[1:0], ex_mem.store_val);
  assign dmem_wstrb = ex_mem.mem_write ? store_strobe(ex_mem.funct3[1:0], ex_mem.result[1:0])
                                       : 4'b0;

  always_comb begin
    mem_wb_next.valid = ex_mem.valid;
    mem_wb_next.rd = ex_mem.rd;
    mem_wb_next.reg_write = ex_mem.reg_write;
    mem_wb_next.value = ex_mem.mem_read
        ? load_extend(ex_mem.funct3, ex_mem.result[1:0], dmem_rdata) : ex_mem.result;
  end

  // ---------------------------------------------------------------- WB
  assign retire = mem_wb.valid;

  // ---------------------------------------------------------------- registers
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      if_id <= '0;
      id_ex <= '0;
      ex_mem <= '0;
      mem_wb <= '0;
    end else begin
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
