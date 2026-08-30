#ifndef PICORUBY_TORCH_H
#define PICORUBY_TORCH_H

#include <stdbool.h>

/* Turn the device torch on (true) or off (false). Returns true on success,
 * false if the device has no controllable torch (e.g. the Simulator). */
bool TORCH_set(bool on);

/* True if this device exposes a controllable torch. */
bool TORCH_available(void);

/* Stop request, port-independent (src/torch.c). The host UI raises it from
 * any thread; the Ruby side polls it from Kernel#sleep (mrblib/torch.rb) and
 * ends the script's `loop` with StopIteration. Clear it before each run. */
void TORCH_request_stop(void);
void TORCH_clear_stop(void);
bool TORCH_stop_requested(void);

#endif /* PICORUBY_TORCH_H */
