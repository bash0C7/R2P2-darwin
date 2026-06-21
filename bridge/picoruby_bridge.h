#ifndef PICORUBY_BRIDGE_H
#define PICORUBY_BRIDGE_H

/* Evaluate Ruby source in a fresh, single-use VM. Returns captured
 * stdout+stderr (including compile diagnostics or an uncaught-exception
 * backtrace) as a malloc'd C string. The caller must free() it. Returns NULL
 * only on allocation/setup failure (out of memory, or tmpfile() failure). */
char *repl_eval(const char *src);

#endif /* PICORUBY_BRIDGE_H */
