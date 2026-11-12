// Observes `tb.dut` without changing it. Compiled as a second top-level module next to
// tb.sv only by scripts/cpi_stack.py and scripts/pipeline_trace.py; `make sim` and
// `make bench` leave it out.
//
// +stack           print why every cycle that retired nothing was lost:
//                  STACK cycles=N instret=M fill=F loaduse=L flush=B icmiss=I dcmiss=D
// +trace=<file>    one line per cycle: the PC in each stage, stall, flush,
//                  forwarding and I-cache miss (format in scripts/pipeline_trace.py)
// +vcd=<file> +vcd_from=A +vcd_to=B   dump this module's signals for cycles A..B
//
// Older steps of the core lack some signals: define PROBE_NO_ICACHE (steps 2 and 3),
// PROBE_NO_TRACE (steps 2 to 4) and PROBE_NO_DCACHE (steps 2 to 5).
module probe;
  // Why a pipeline register holds a bubble.
  typedef enum logic [2:0] {
    INSTR,    // not a bubble
    FILL,     // reset: the pipeline has not filled yet
    LOADUSE,  // load-use stall
    FLUSH,    // misprediction in EX cleared IF/ID and ID/EX
    ICMISS,   // IF waited for an instruction cache line
    DCMISS    // MEM waited for a data cache line; every stage held
  } cause_t;

  wire clk = tb.clk;
  wire rst_n = tb.rst_n;
  wire stall = tb.dut.stall;
  wire flush = tb.dut.redirect;
  // The tohost store ends the run on this edge, which tb does not count.
  wire done = tb.dmem_wstrb != 4'b0 && (tb.dmem_addr & ~32'h3) == tb.TOHOST;
`ifdef PROBE_NO_ICACHE
  wire icmiss = 1'b0;
`else
  wire icmiss = !tb.dut.cache_hit;
`endif
`ifdef PROBE_NO_DCACHE
  wire dstall = 1'b0;
`else
  wire dstall = tb.dut.dstall;
`endif

  // The cause carried by IF/ID, ID/EX, EX/MEM and MEM/WB, updated like the core's
  // own registers.
  cause_t c_id = FILL;
  cause_t c_ex = FILL;
  cause_t c_mem = FILL;
  cause_t c_wb = FILL;
  int lost[6];  // indexed by cause_t

  initial for (int i = 0; i < 6; i++) lost[i] = 0;

  // A data miss holds every register, WB included, and nothing retires.
  always @(posedge clk)
    if (rst_n && !done && dstall) lost[DCMISS] <= lost[DCMISS] + 1;
    else if (rst_n && !done) begin
      c_id <= flush ? FLUSH : stall ? c_id : icmiss ? ICMISS : INSTR;
      c_ex <= flush ? FLUSH : stall ? LOADUSE : c_id;
      c_mem <= c_ex;
      c_wb <= c_mem;
      if (!tb.dut.retire) lost[c_wb] <= lost[c_wb] + 1;
    end

  final
    if ($test$plusargs("stack"))
      $display("STACK cycles=%0d instret=%0d fill=%0d loaduse=%0d flush=%0d icmiss=%0d dcmiss=%0d",
               tb.run_cycles, tb.instret, lost[FILL], lost[LOADUSE], lost[FLUSH],
               lost[ICMISS], lost[DCMISS]);

`ifndef PROBE_NO_TRACE
  // Stage PCs for the trace and the waveform. EX/MEM and MEM/WB do not carry a PC,
  // so it is followed here.
  wire [31:0] pc_if = tb.dut.pc;
  wire [31:0] pc_id = tb.dut.if_id.pc;
  wire [31:0] pc_ex = tb.dut.id_ex.pc;
  logic [31:0] pc_mem = 0, pc_wb = 0;
  wire v_id = tb.dut.if_id.valid;
  wire v_ex = tb.dut.id_ex.valid;
  logic v_mem = 0, v_wb = 0;
  // Operand source in EX: 2 = EX/MEM, 1 = MEM/WB, 0 = register file or unused.
  wire [1:0] fwd_a = !(v_ex && tb.dut.id_ex.uses_rs1) ? 2'd0
      : tb.dut.a_from_mem ? 2'd2 : tb.dut.a_from_wb ? 2'd1 : 2'd0;
  wire [1:0] fwd_b = !(v_ex && tb.dut.id_ex.uses_rs2) ? 2'd0
      : tb.dut.b_from_mem ? 2'd2 : tb.dut.b_from_wb ? 2'd1 : 2'd0;
  // Control flow in EX: was it predicted taken by the BTB, and was it taken?
  wire ex_control = v_ex && tb.dut.is_control;
  wire ex_pred_taken = v_ex && tb.dut.id_ex.pred_taken;
  wire ex_taken = v_ex && tb.dut.taken;

  always @(posedge clk)
    if (rst_n && !dstall) begin
      pc_mem <= pc_ex;
      v_mem <= v_ex;
      pc_wb <= pc_mem;
      v_wb <= v_mem;
    end

  int trace_fd = 0;
  string trace_file, vcd_file;
  int vcd_from = 0, vcd_to = -1;

  initial begin
    if ($value$plusargs("trace=%s", trace_file)) begin
      trace_fd = $fopen(trace_file, "w");
      if (trace_fd == 0) $fatal(1, "cannot open %s", trace_file);
    end
    if ($value$plusargs("vcd=%s", vcd_file)) begin
      void'($value$plusargs("vcd_from=%d", vcd_from));
      void'($value$plusargs("vcd_to=%d", vcd_to));
      $dumpfile(vcd_file);
      $dumpvars(1, probe);
      $dumpoff;
    end
  end

  // Sampled before each rising edge: the state of the cycle that edge ends.
  always @(posedge clk)
    if (rst_n && !done && trace_fd != 0)
      $fwrite(trace_fd, "%0d %h %h %0d %h %0d %h %0d %h %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
              tb.run_cycles, pc_if, pc_id, v_id, pc_ex, v_ex, pc_mem, v_mem, pc_wb, v_wb,
              stall, flush, icmiss, fwd_a, fwd_b, ex_control, ex_pred_taken, ex_taken);

  // The window starts half a cycle early so the first edge is in the dump.
  always @(negedge clk)
    if (vcd_file != "" && rst_n) begin
      if (tb.run_cycles == vcd_from) $dumpon;
      if (tb.run_cycles == vcd_to + 1) $dumpoff;
    end

  final if (trace_fd != 0) $fclose(trace_fd);
`endif
endmodule
