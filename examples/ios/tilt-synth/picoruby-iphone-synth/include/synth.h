#ifndef PICORUBY_SYNTH_H
#define PICORUBY_SYNTH_H

#include <stdbool.h>

/* Start the audio engine (sine carrier + FM modulator). True on success. */
bool SYNTH_start(void);

/* Stop the audio engine. True on success. */
bool SYNTH_stop(void);

/* Set the carrier (note) frequency in Hz. True on success. */
bool SYNTH_set_note(double freq_hz);

/* Set the FM modulation depth, 0.0-1.0. True on success. */
bool SYNTH_set_fm_depth(double depth);

#endif /* PICORUBY_SYNTH_H */
