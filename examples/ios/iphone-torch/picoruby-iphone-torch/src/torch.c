#include <stdbool.h>
#include "picoruby.h"
#include "../include/torch.h"

/* A plain flag is enough: one writer (the UI), one reader (the VM thread),
 * and the reader only ever polls it between sleeps. */
static volatile bool stop_requested = false;

void TORCH_request_stop(void) { stop_requested = true; }
void TORCH_clear_stop(void)   { stop_requested = false; }
bool TORCH_stop_requested(void) { return stop_requested; }

#if defined(PICORB_VM_MRUBY)

#include "mruby/torch.c"

#endif
