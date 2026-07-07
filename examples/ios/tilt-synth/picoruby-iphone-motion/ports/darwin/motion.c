#include "../../include/motion.h"

/* Provided by the PicoMotionDarwin Swift package (@c exports), resolved at
 * app link time. Declared here so the cross-build needs no generated
 * -Swift.h (same technique as picoruby-iphone-torch's ports/darwin/torch.c). */
extern int    pmotion_available(void);
extern double pmotion_pitch(void);
extern double pmotion_roll(void);

bool
MOTION_available(void)
{
  return pmotion_available() != 0;
}

double
MOTION_pitch(void)
{
  return pmotion_pitch();
}

double
MOTION_roll(void)
{
  return pmotion_roll();
}
