/* Embench board support for the rv32i-pipeline testbench. CPU_MHZ scales each
   benchmark's iteration count; 1 is the suite's reference workload. WARMUP_HEAT
   is the warm-up runs before the timed one, as in the suite's build script. */
#define CPU_MHZ 1
#define WARMUP_HEAT 1
