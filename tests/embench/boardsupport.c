/* Embench board hooks. The testbench measures the whole run, from reset to the
   tohost store, so the triggers do nothing. */
#include "support.h"

void initialise_board(void) {}
void start_trigger(void) {}
void stop_trigger(void) {}
