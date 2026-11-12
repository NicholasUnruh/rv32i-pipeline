// Splits one RV32I instruction into register numbers, the immediate and control
// signals. Instructions outside RV32I raise `illegal` and do nothing.
module decoder (
    input  logic [31:0] instr,
    output logic [4:0]  rs1,
    output logic [4:0]  rs2,
    output logic [4:0]  rd,
    output logic        uses_rs1,   // the instruction reads rs1 (for hazard checks)
    output logic        uses_rs2,
    output logic [31:0] imm,
    output logic [3:0]  alu_op,     // {funct7[5], funct3}; see alu.sv
    output logic        alu_a_pc,   // ALU input a is the PC (auipc)
    output logic        alu_a_zero, // ALU input a is zero (lui)
    output logic        alu_b_imm,  // ALU input b is the immediate
    output logic        reg_write,
    output logic        mem_read,
    output logic        mem_write,
    output logic        branch,
    output logic        jal,
    output logic        jalr,
    output logic [2:0]  funct3,     // memory width and sign, branch condition
    output logic        illegal
);
  localparam logic [6:0] OP_LUI = 7'b0110111;
  localparam logic [6:0] OP_AUIPC = 7'b0010111;
  localparam logic [6:0] OP_JAL = 7'b1101111;
  localparam logic [6:0] OP_JALR = 7'b1100111;
  localparam logic [6:0] OP_BRANCH = 7'b1100011;
  localparam logic [6:0] OP_LOAD = 7'b0000011;
  localparam logic [6:0] OP_STORE = 7'b0100011;
  localparam logic [6:0] OP_IMM = 7'b0010011;
  localparam logic [6:0] OP_REG = 7'b0110011;
  localparam logic [6:0] OP_FENCE = 7'b0001111;
  localparam logic [6:0] SRA_SUB = 7'b0100000;  // funct7 of sub, sra and srai

  logic [6:0] opcode;
  logic [6:0] funct7;
  logic [31:0] imm_i, imm_s, imm_b, imm_u, imm_j;

  assign opcode = instr[6:0];
  assign funct3 = instr[14:12];
  assign funct7 = instr[31:25];
  assign rd = instr[11:7];
  assign rs1 = instr[19:15];
  assign rs2 = instr[24:20];

  assign uses_rs1 = opcode == OP_JALR || opcode == OP_BRANCH || opcode == OP_LOAD
      || opcode == OP_STORE || opcode == OP_IMM || opcode == OP_REG;
  assign uses_rs2 = opcode == OP_BRANCH || opcode == OP_STORE || opcode == OP_REG;

  assign imm_i = {{21{instr[31]}}, instr[30:20]};
  assign imm_s = {{21{instr[31]}}, instr[30:25], instr[11:7]};
  assign imm_b = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};
  assign imm_u = {instr[31:12], 12'b0};
  assign imm_j = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};

  always_comb begin
    imm = imm_i;
    alu_op = 4'b0000;  // add
    alu_a_pc = 1'b0;
    alu_a_zero = 1'b0;
    alu_b_imm = 1'b0;
    reg_write = 1'b0;
    mem_read = 1'b0;
    mem_write = 1'b0;
    branch = 1'b0;
    jal = 1'b0;
    jalr = 1'b0;
    illegal = 1'b0;

    case (opcode)
      OP_LUI: begin
        imm = imm_u;
        alu_a_zero = 1'b1;
        alu_b_imm = 1'b1;
        reg_write = 1'b1;
      end
      OP_AUIPC: begin
        imm = imm_u;
        alu_a_pc = 1'b1;
        alu_b_imm = 1'b1;
        reg_write = 1'b1;
      end
      OP_JAL: begin
        imm = imm_j;
        jal = 1'b1;
        reg_write = 1'b1;
      end
      OP_JALR: begin
        jalr = 1'b1;
        reg_write = 1'b1;
      end
      OP_BRANCH: begin
        imm = imm_b;
        branch = 1'b1;
        illegal = funct3 == 3'b010 || funct3 == 3'b011;
      end
      OP_LOAD: begin
        alu_b_imm = 1'b1;
        mem_read = 1'b1;
        reg_write = 1'b1;
        illegal = funct3 == 3'b011 || funct3 == 3'b110 || funct3 == 3'b111;
      end
      OP_STORE: begin
        imm = imm_s;
        alu_b_imm = 1'b1;
        mem_write = 1'b1;
        illegal = funct3 > 3'b010;
      end
      OP_IMM: begin
        // Only the right shifts read funct7 (srai); for the rest it is immediate bits.
        alu_op = {funct3 == 3'b101 && funct7 == SRA_SUB, funct3};
        alu_b_imm = 1'b1;
        reg_write = 1'b1;
        illegal = (funct3 == 3'b001 && funct7 != 7'b0)
            || (funct3 == 3'b101 && funct7 != 7'b0 && funct7 != SRA_SUB);
      end
      OP_REG: begin
        alu_op = {funct7 == SRA_SUB, funct3};
        reg_write = 1'b1;
        illegal = funct7 != 7'b0
            && !(funct7 == SRA_SUB && (funct3 == 3'b000 || funct3 == 3'b101));
      end
      OP_FENCE: ;  // single hart, no caches between stores and loads: a no-op
      default: illegal = 1'b1;
    endcase

    if (illegal) begin
      reg_write = 1'b0;
      mem_read = 1'b0;
      mem_write = 1'b0;
      branch = 1'b0;
    end
  end
endmodule
