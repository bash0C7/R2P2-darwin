#ifndef PICORUBY_BRIDGE_H
#define PICORUBY_BRIDGE_H

/* Evaluate Ruby source. Returns captured stdout+stderr (including compile
 * diagnostics or an uncaught-exception backtrace) as a malloc'd C string.
 * The caller must free() it. Returns NULL only on VM-open failure. */
char *picoruby_eval(const char *src);

#endif /* PICORUBY_BRIDGE_H */
