#ifndef PICORUBY_BRIDGE_H
#define PICORUBY_BRIDGE_H

/* Evaluate Ruby source in a fresh, single-use VM. Returns captured
 * stdout+stderr (including compile diagnostics or an uncaught-exception
 * backtrace) as a malloc'd C string. The caller must free() it. Returns NULL
 * only on allocation/setup failure (out of memory, tmpfile(), or fd-save
 * failure). */
char *repl_eval(const char *src);

/* Persistent VM. vm_open allocates a heap, opens a VM, and runs boot_src
 * (which should define classes and assign a dispatcher object to the global
 * $app). Returns NULL on allocation failure OR if boot_src fails to compile,
 * otherwise an opaque handle. vm_call invokes
 * `method` on $app with a single String argument `arg`, returning captured
 * stdout+stderr as a malloc'd string the caller must free() (NULL on setup
 * failure). vm_close tears the VM down. All three MUST be called from one
 * thread. */
void *vm_open(const char *boot_src);
char *vm_call(void *vm, const char *method, const char *arg);
void  vm_close(void *vm);

#endif /* PICORUBY_BRIDGE_H */
