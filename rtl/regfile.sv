// 32 x 32-bit register file: two combinational reads, one write on the clock edge.
// x0 always reads zero. A read of the register being written returns the new value,
// so an instruction in decode sees the result of the one in writeback.
module regfile (
    input  logic        clk,
    input  logic [4:0]  raddr1,
    input  logic [4:0]  raddr2,
    output logic [31:0] rdata1,
    output logic [31:0] rdata2,
    input  logic        we,
    input  logic [4:0]  waddr,
    input  logic [31:0] wdata
);
  logic [31:0] regs[1:31];

  always_ff @(posedge clk) if (we && waddr != 5'd0) regs[waddr] <= wdata;

  assign rdata1 = raddr1 == 5'd0 ? 32'b0 : we && waddr == raddr1 ? wdata : regs[raddr1];
  assign rdata2 = raddr2 == 5'd0 ? 32'b0 : we && waddr == raddr2 ? wdata : regs[raddr2];
endmodule
