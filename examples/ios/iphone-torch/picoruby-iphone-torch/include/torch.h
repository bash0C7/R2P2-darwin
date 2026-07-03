#ifndef PICORUBY_TORCH_H
#define PICORUBY_TORCH_H

#include <stdbool.h>

/* Turn the device torch on (true) or off (false). Returns true on success,
 * false if the device has no controllable torch (e.g. the Simulator). */
bool TORCH_set(bool on);

/* True if this device exposes a controllable torch. */
bool TORCH_available(void);

#endif /* PICORUBY_TORCH_H */
