// RV32I integer ALU. The op code is {funct7[5], funct3}, so the decoder can pass
// register-register instruction bits straight through.
module alu (
    input  logic [3:0]  op,
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic [31:0] y
);
  localparam logic [3:0] ADD = 4'b0000;
  localparam logic [3:0] SUB = 4'b1000;
  localparam logic [3:0] SLL = 4'b0001;
  localparam logic [3:0] SLT = 4'b0010;
  localparam logic [3:0] SLTU = 4'b0011;
  localparam logic [3:0] XOR = 4'b0100;
  localparam logic [3:0] SRL = 4'b0101;
  localparam logic [3:0] SRA = 4'b1101;
  localparam logic [3:0] OR = 4'b0110;
  localparam logic [3:0] AND = 4'b0111;

  logic [4:0] shamt;
  assign shamt = b[4:0];

  always_comb begin
    case (op)
      ADD:     y = a + b;
      SUB:     y = a - b;
      SLL:     y = a << shamt;
      SLT:     y = {31'b0, $signed(a) < $signed(b)};
      SLTU:    y = {31'b0, a < b};
      XOR:     y = a ^ b;
      SRL:     y = a >> shamt;
      SRA:     y = $unsigned($signed(a) >>> shamt);
      OR:      y = a | b;
      AND:     y = a & b;
      default: y = 32'b0;
    endcase
  end
endmodule
