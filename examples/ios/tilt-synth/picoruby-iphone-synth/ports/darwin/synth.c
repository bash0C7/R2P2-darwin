#include "../../include/synth.h"

/* Provided by the PicoSynthDarwin Swift package (@c exports), resolved at
 * app link time. */
extern int psynth_start(void);
extern int psynth_stop(void);
extern int psynth_set_note(double freq_hz);
extern int psynth_set_fm_depth(double depth);

bool
SYNTH_start(void)
{
  return psynth_start() != 0;
}

bool
SYNTH_stop(void)
{
  return psynth_stop() != 0;
}

bool
SYNTH_set_note(double freq_hz)
{
  return psynth_set_note(freq_hz) != 0;
}

bool
SYNTH_set_fm_depth(double depth)
{
  return psynth_set_fm_depth(depth) != 0;
}
