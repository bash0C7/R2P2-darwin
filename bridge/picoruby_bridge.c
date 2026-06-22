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

mrb_state *global_mrb = NULL;

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

/* Run a compiled irep as a task and surface any exception, mirroring
 * repl_eval's task-scheduler handling. */
static void run_irep(mrb_state *mrb, mrc_ccontext *cc, mrc_irep *irep) {
  mrb_value name = mrb_str_new_cstr(mrb, "main");
  mrb_value task = mrc_create_task(cc, irep, name, mrb_nil_value(),
                                   mrb_obj_value(mrb->top_self));
  if (mrb_nil_p(task)) { fprintf(stderr, "mrc_create_task failed\n"); return; }
  int ai = mrb_gc_arena_save(mrb);
  mrb_gc_protect(mrb, task);
  mrb_task_run(mrb);
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
  dup2(fileno(cap), 1);
  dup2(fileno(cap), 2);

  /* Allocate a fresh, zero-initialized heap for each eval.
   * Using calloc (zero-initialized) ensures estalloc starts from a
   * known-good state and stale pointers from a previous run do not persist. */
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

typedef struct {
  const char *boot_src;
  mrb_bool ok;
} vm_boot_args;

static mrb_value
vm_boot_body(mrb_state *mrb, void *ud)
{
  vm_boot_args *args = (vm_boot_args *)ud;
  size_t shim_len = strlen(PUTS_SHIM), src_len = strlen(args->boot_src);
  char *combined = (char *)malloc(shim_len + src_len + 1);
  if (combined == NULL) {
    fprintf(stderr, "[vm_open] malloc combined failed\n");
    mrb_raise(mrb, E_RUNTIME_ERROR, "malloc failed");
  }
  memcpy(combined, PUTS_SHIM, shim_len);
  memcpy(combined + shim_len, args->boot_src, src_len + 1);

  fprintf(stderr, "[vm_open] compiling (%zu bytes)\n", shim_len + src_len);
  mrc_ccontext *cc = mrc_ccontext_new(mrb);
  mrc_ccontext_filename(cc, "main");
  const uint8_t *u = (const uint8_t *)combined;
  mrc_irep *irep = mrc_load_string_cxt(cc, &u, strlen(combined));
  if (irep == NULL) {
    fprintf(stderr, "[vm_open] compile failed\n");
    print_diagnostics(cc);
    mrc_ccontext_free(cc);
    free(combined);
    mrb_raise(mrb, E_RUNTIME_ERROR, "compile failed");
  }
  fprintf(stderr, "[vm_open] running boot irep\n");
  run_irep(mrb, cc, irep);
  fprintf(stderr, "[vm_open] boot done\n");
  mrc_ccontext_free(cc);
  free(combined);
  args->ok = TRUE;
  return mrb_nil_value();
}

void *vm_open(const char *boot_src) {
  fprintf(stderr, "[vm_open] start HEAP_SIZE=%d\n", HEAP_SIZE);
  uint8_t *heap = (uint8_t *)calloc(1, HEAP_SIZE);
  if (heap == NULL) { fprintf(stderr, "[vm_open] calloc failed\n"); return NULL; }
  mrb_state *mrb = mrb_open_with_custom_alloc(heap, HEAP_SIZE);
  fprintf(stderr, "[vm_open] mrb=%p\n", (void*)mrb);
  if (mrb == NULL) { free(heap); return NULL; }
  global_mrb = mrb;

  /* Use mrb_protect_error so any Ruby exception (OOM, compile error, runtime)
   * is caught here rather than reaching exc_throw with a NULL jmp → abort(). */
  vm_boot_args args = { boot_src, FALSE };
  mrb_bool error = FALSE;
  mrb_value exc = mrb_protect_error(mrb, vm_boot_body, &args, &error);
  if (error || !args.ok) {
    fprintf(stderr, "[vm_open] boot failed (error=%d ok=%d)\n", (int)error, (int)args.ok);
    /* Do NOT call mrb_close: boot may have corrupted the estalloc heap, and
     * mrb_close would walk every GC object triggering a heap-corruption assert.
     * The entire heap is a single calloc block — freeing it is safe and complete. */
    global_mrb = NULL; free(heap);
    return NULL;
  }

  vm_handle *h = (vm_handle *)malloc(sizeof(vm_handle));
  if (h == NULL) { mrb_close(mrb); global_mrb = NULL; free(heap); return NULL; }
  h->mrb = mrb; h->heap = heap;
  fprintf(stderr, "[vm_open] success h=%p\n", (void*)h);
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
