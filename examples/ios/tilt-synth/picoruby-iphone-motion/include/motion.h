#ifndef PICORUBY_MOTION_H
#define PICORUBY_MOTION_H

#include <stdbool.h>

/* True if this device exposes Device Motion (false in the Simulator). */
bool MOTION_available(void);

/* Attitude pitch, in degrees. 0 if unavailable. */
double MOTION_pitch(void);

/* Attitude roll, in degrees. 0 if unavailable. */
double MOTION_roll(void);

#endif /* PICORUBY_MOTION_H */
