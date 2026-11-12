// 64 KB of block RAM with two ports, both synchronous: read data appears the
// cycle after the address. Port A reads instruction lines; port B is the data
// port with byte write enables. Follows Quartus's byte-enabled true dual-port
// template so it maps onto M10K blocks.
module ram #(
    parameter int ADDR_BITS = 14,          // 16 K words
    parameter INIT_FILE = "program.hex"    // $readmemh words from address 0
) (
    input  logic                 clk,
    input  logic [ADDR_BITS-1:0] a_addr,
    output logic [31:0]          a_rdata,
    input  logic [ADDR_BITS-1:0] b_addr,
    input  logic [3:0]           b_wstrb,
    input  logic [31:0]          b_wdata,
    output logic [31:0]          b_rdata
);
  logic [3:0][7:0] mem[0:(1 << ADDR_BITS) - 1];

  initial $readmemh(INIT_FILE, mem);

  always_ff @(posedge clk) a_rdata <= mem[a_addr];

  always_ff @(posedge clk) begin
    if (b_wstrb[0]) mem[b_addr][0] <= b_wdata[7:0];
    if (b_wstrb[1]) mem[b_addr][1] <= b_wdata[15:8];
    if (b_wstrb[2]) mem[b_addr][2] <= b_wdata[23:16];
    if (b_wstrb[3]) mem[b_addr][3] <= b_wdata[31:24];
    b_rdata <= mem[b_addr];
  end
endmodule
