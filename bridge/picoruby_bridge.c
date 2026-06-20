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
#define HEAP_SIZE (1024 * 2000)
#endif

static uint8_t vm_heap[HEAP_SIZE] __attribute__((aligned(16)));
mrb_state *global_mrb = NULL;

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

char *picoruby_eval(const char *src) {
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
  dup2(fileno(cap), 1);
  dup2(fileno(cap), 2);

  mrb_state *mrb = mrb_open_with_custom_alloc(vm_heap, HEAP_SIZE);
  global_mrb = mrb;
  if (mrb) {
    mrc_ccontext *cc = mrc_ccontext_new(mrb);
    mrc_ccontext_filename(cc, "main");
    const uint8_t *u = (const uint8_t *)combined;
    mrc_irep *irep = mrc_load_string_cxt(cc, &u, strlen(combined));
    if (irep == NULL) {
      print_diagnostics(cc);
    } else {
      mrb_value name = mrb_str_new_cstr(mrb, "main");
      mrb_value task = mrc_create_task(cc, irep, name,
                                       mrb_nil_value(),
                                       mrb_obj_value(mrb->top_self));
      if (!mrb_nil_p(task)) {
        /* Protect the task object from GC while the scheduler runs so we can
         * retrieve the result afterwards. */
        int ai = mrb_gc_arena_save(mrb);
        mrb_gc_protect(mrb, task);
        mrb_task_run(mrb);
        /* The task scheduler captures exceptions as the task result rather
         * than setting mrb->exc. Use mrb_exception_p (type check only, no
         * alloc) to avoid crashing inside mrb_obj_is_kind_of. */
        mrb_value result = mrb_task_value(mrb, task);
        if (mrb_exception_p(result)) {
          mrb->exc = mrb_obj_ptr(result);
          mrb_print_error(mrb);
          mrb->exc = NULL;
        }
        mrb_gc_arena_restore(mrb, ai);
      } else {
        fprintf(stderr, "mrc_create_task failed\n");
      }
    }
    mrc_ccontext_free(cc);
    mrb_close(mrb);
    global_mrb = NULL;
  }

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
