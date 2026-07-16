#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>

#if !defined(PICORB_PLATFORM_POSIX)
#define PICORB_PLATFORM_POSIX 1
#endif

#include "picoruby.h"
#include "task.h"
#include "picoruby_bridge.h"

#ifndef HEAP_SIZE
/* 8 MB heap; the default 2 MB is insufficient on iOS arm64 where the
 * compiled Ruby VM + compiler + task scheduler has a larger footprint
 * than the host x86_64 build. */
#define HEAP_SIZE (1024 * 8000)
#endif

/* Defined in mruby-compiler (ccontext.c); the prism xallocator routes its
 * allocations through it, so keep it pointed at the live VM. */
extern mrb_state *global_mrb;

typedef struct { mrb_state *mrb; uint8_t *heap; } vm_handle;

/* The reduced VM has core `print` but no `puts`; define puts via print. One
 * physical line so user line numbers shift by exactly 1. */
static const char *PUTS_SHIM =
  "def puts(*a); a.each { |x| print x.to_s; print \"\\n\" }; print \"\\n\" if a.empty?; nil; end\n";

static void print_diagnostics(mrc_ccontext *cc) {
  mrc_diagnostic_list *d = cc->diagnostic_list;
  while (d) {
    fprintf(stderr, "main:%d:%d: %s\n", d->line, d->column, d->message);
    d = d->next;
  }
}

/* Run a compiled irep as a task and surface any uncaught exception as a
 * printed backtrace on stderr instead of crashing. */
static void run_irep(mrb_state *mrb, mrc_ccontext *cc, mrc_irep *irep) {
  mrb_value name = mrb_str_new_cstr(mrb, "main");
  mrb_value task = mrc_create_task(cc, irep, name, mrb_nil_value(),
                                   mrb_obj_value(mrb->top_self));
  if (mrb_nil_p(task)) { fprintf(stderr, "mrc_create_task failed\n"); return; }
  /* Protect the task object from GC while the scheduler runs so the result
   * can be retrieved afterwards. */
  int ai = mrb_gc_arena_save(mrb);
  mrb_gc_protect(mrb, task);
  mrb_task_run(mrb);
  /* The task scheduler captures exceptions as the task result rather than
   * setting mrb->exc. Use mrb_exception_p (type check only, no alloc) to
   * avoid crashing inside mrb_obj_is_kind_of. */
  mrb_value result = mrb_task_value(mrb, task);
  if (mrb_exception_p(result)) {
    mrb->exc = mrb_obj_ptr(result);
    mrb_print_error(mrb);
    mrb->exc = NULL;
  }
  mrb_gc_arena_restore(mrb, ai);
}

char *repl_eval(const char *src) {
  /* prepend the puts shim */
  size_t shim_len = strlen(PUTS_SHIM);
  size_t src_len = strlen(src);
  char *combined = (char *)malloc(shim_len + src_len + 1);
  if (combined == NULL) return NULL;
  memcpy(combined, PUTS_SHIM, shim_len);
  memcpy(combined + shim_len, src, src_len + 1);

  FILE *cap = tmpfile();
  if (cap == NULL) { free(combined); return NULL; }
  fflush(stdout); fflush(stderr);
  int saved_out = dup(1), saved_err = dup(2);
  if (saved_out < 0 || saved_err < 0) {
    if (saved_out >= 0) close(saved_out);
    if (saved_err >= 0) close(saved_err);
    fclose(cap); free(combined);
    return NULL;
  }
  dup2(fileno(cap), 1);
  dup2(fileno(cap), 2);

  /* Allocate a fresh, zero-initialized heap for each eval so estalloc starts
   * from a known-good state and stale pointers from a previous run do not
   * persist. */
  uint8_t *heap = (uint8_t *)calloc(1, HEAP_SIZE);
  if (heap == NULL) {
    dup2(saved_out, 1); dup2(saved_err, 2);
    close(saved_out); close(saved_err);
    fclose(cap); free(combined);
    return NULL;
  }
  mrb_state *mrb = mrb_open_with_custom_alloc(heap, HEAP_SIZE);
  global_mrb = mrb;
  if (mrb) {
    mrc_ccontext *cc = mrc_ccontext_new(mrb);
    mrc_ccontext_filename(cc, "main");
    const uint8_t *u = (const uint8_t *)combined;
    mrc_irep *irep = mrc_load_string_cxt(cc, &u, strlen(combined));
    if (irep == NULL) {
      print_diagnostics(cc);
    } else {
      run_irep(mrb, cc, irep);
    }
    mrc_ccontext_free(cc);
    mrb_close(mrb);
    global_mrb = NULL;
  }
  free(heap);

  fflush(stdout); fflush(stderr);
  dup2(saved_out, 1); dup2(saved_err, 2);
  close(saved_out); close(saved_err);
  free(combined);

  fseek(cap, 0, SEEK_END);
  long n = ftell(cap);
  if (n < 0) n = 0;
  rewind(cap);
  char *buf = (char *)malloc((size_t)n + 1);
  if (buf) {
    size_t got = fread(buf, 1, (size_t)n, cap);
    buf[got] = '\0';
  }
  fclose(cap);
  return buf;
}

void *vm_open(const char *boot_src) {
  uint8_t *heap = (uint8_t *)calloc(1, HEAP_SIZE);
  if (heap == NULL) return NULL;
  mrb_state *mrb = mrb_open_with_custom_alloc(heap, HEAP_SIZE);
  if (mrb == NULL) { free(heap); return NULL; }
  global_mrb = mrb;
  size_t shim_len = strlen(PUTS_SHIM), src_len = strlen(boot_src);
  char *combined = (char *)malloc(shim_len + src_len + 1);
  if (combined == NULL) { mrb_close(mrb); global_mrb = NULL; free(heap); return NULL; }
  memcpy(combined, PUTS_SHIM, shim_len);
  memcpy(combined + shim_len, boot_src, src_len + 1);
  mrc_ccontext *cc = mrc_ccontext_new(mrb);
  mrc_ccontext_filename(cc, "main");
  const uint8_t *u = (const uint8_t *)combined;
  mrc_irep *irep = mrc_load_string_cxt(cc, &u, strlen(combined));
  if (irep == NULL) {
    /* The boot Ruby is bundled and fixed, so a compile failure is a build-time
     * bug. Treat it as fatal rather than handing back a VM whose $app is nil. */
    print_diagnostics(cc);
    mrc_ccontext_free(cc);
    free(combined);
    mrb_close(mrb);
    global_mrb = NULL;
    free(heap);
    return NULL;
  }
  run_irep(mrb, cc, irep);
  mrc_ccontext_free(cc);
  free(combined);
  vm_handle *h = (vm_handle *)malloc(sizeof(vm_handle));
  if (h == NULL) { mrb_close(mrb); global_mrb = NULL; free(heap); return NULL; }
  h->mrb = mrb; h->heap = heap;
  return h;
}

char *vm_call(void *vm, const char *method, const char *arg) {
  vm_handle *h = (vm_handle *)vm;
  mrb_state *mrb = h->mrb;
  global_mrb = mrb;
  FILE *cap = tmpfile();
  if (cap == NULL) return NULL;
  fflush(stdout); fflush(stderr);
  int saved_out = dup(1), saved_err = dup(2);
  if (saved_out < 0 || saved_err < 0) {
    if (saved_out >= 0) close(saved_out);
    if (saved_err >= 0) close(saved_err);
    fclose(cap);
    return NULL;
  }
  dup2(fileno(cap), 1); dup2(fileno(cap), 2);

  int ai = mrb_gc_arena_save(mrb);
  mrb_value app = mrb_gv_get(mrb, mrb_intern_lit(mrb, "$app"));
  mrb_value a = mrb_str_new_cstr(mrb, arg);
  mrb_value ret = mrb_funcall(mrb, app, method, 1, a);
  (void)ret;
  if (mrb->exc) { mrb_print_error(mrb); mrb->exc = NULL; }
  mrb_gc_arena_restore(mrb, ai);

  fflush(stdout); fflush(stderr);
  dup2(saved_out, 1); dup2(saved_err, 2);
  close(saved_out); close(saved_err);
  fseek(cap, 0, SEEK_END);
  long n = ftell(cap); if (n < 0) n = 0;
  rewind(cap);
  char *buf = (char *)malloc((size_t)n + 1);
  if (buf) { size_t got = fread(buf, 1, (size_t)n, cap); buf[got] = '\0'; }
  fclose(cap);
  return buf;
}

void vm_close(void *vm) {
  vm_handle *h = (vm_handle *)vm;
  if (h == NULL) return;
  mrb_close(h->mrb);
  global_mrb = NULL;
  free(h->heap);
  free(h);
}
