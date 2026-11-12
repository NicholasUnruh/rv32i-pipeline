// Single-cycle RV32I core: every instruction fetches, executes and writes back in
// one clock. Ports and the memory protocol are in docs/interface.md.
module core (
    input  logic        clk,
    input  logic        rst_n,
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata,
    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    output logic [3:0]  dmem_wstrb,
    input  logic [31:0] dmem_rdata
);
  localparam logic [31:0] RESET_PC = 32'h8000_0000;

  logic [31:0] pc, pc_plus4, next_pc;
  logic [31:0] instr;

  // Decoded instruction
  logic [4:0] rs1, rs2, rd;
  logic [31:0] imm;
  logic [3:0] alu_op;
  logic alu_a_pc, alu_a_zero, alu_b_imm;
  logic reg_write, mem_read, mem_write, branch, jal, jalr, illegal;
  logic [2:0] funct3;

  logic [31:0] rs1_val, rs2_val, alu_a, alu_b, alu_y;
  logic [31:0] jump_target, load_val, rd_val;
  logic taken;

  assign instr = imem_rdata;
  assign imem_addr = pc;
  assign pc_plus4 = pc + 32'd4;

  decoder dec (
      .instr(instr),
      .rs1(rs1),
      .rs2(rs2),
      .rd(rd),
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
      .we(reg_write && rst_n),
      .waddr(rd),
      .wdata(rd_val)
  );

  assign alu_a = alu_a_pc ? pc : alu_a_zero ? 32'b0 : rs1_val;
  assign alu_b = alu_b_imm ? imm : rs2_val;

  alu ex_alu (
      .op(alu_op),
      .a(alu_a),
      .b(alu_b),
      .y(alu_y)
  );

  // Control flow: branches and jal are PC-relative; jalr clears bit 0.
  assign taken = branch && branch_taken(funct3, rs1_val, rs2_val);
  assign jump_target = jalr ? (rs1_val + imm) & ~32'd1 : pc + imm;
  assign next_pc = (taken || jal || jalr) ? jump_target : pc_plus4;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) pc <= RESET_PC;
    else pc <= next_pc;
  end

  // Data memory
  assign dmem_addr = alu_y;
  assign dmem_wdata = store_data(funct3[1:0], rs2_val);
  assign dmem_wstrb = mem_write && rst_n ? store_strobe(funct3[1:0], alu_y[1:0]) : 4'b0;
  assign load_val = load_extend(funct3, alu_y[1:0], dmem_rdata);

  assign rd_val = (jal || jalr) ? pc_plus4 : mem_read ? load_val : alu_y;

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
    if (rst_n) assert (!illegal) else $error("illegal instruction %h at %h", instr, pc);
`endif
endmodule
