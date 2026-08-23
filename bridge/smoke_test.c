#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "picoruby_bridge.h"

static int check(const char *label, const char *src, const char *needle) {
  char *out = repl_eval(src);
  if (out == NULL) { printf("FAIL %s: NULL\n", label); return 1; }
  int ok = strstr(out, needle) != NULL;
  printf("%s %s: %s", ok ? "PASS" : "FAIL", label, out);
  if (!ok) printf("  (expected to contain: %s)\n", needle);
  free(out);
  return ok ? 0 : 1;
}

/* Regression test for the vm_call dispatch context: picoruby-ble waits on
 * Task::Queue#pop, which mruby-task's task_queue.c rejects on the root
 * context ("blocking pop can only be called from within a task"). vm_call
 * must therefore run the dispatch inside a task. A 50ms-timeout pop on an
 * empty queue parks and returns nil in task context; on the root context it
 * raises instead, so "pop:timeout" only appears when the dispatch ran in a
 * task. */
static int test_vm_call_blocking_pop(void) {
  const char *boot =
    "class Demo\n"
    "  def wait(a)\n"
    "    q = Task::Queue.new\n"
    "    v = q.pop(timeout_ms: 50)\n"
    "    if v == nil\n"
    "      print \"pop:timeout\"\n"
    "    else\n"
    "      print \"pop:got\"\n"
    "    end\n"
    "  end\n"
    "end\n"
    "$app = Demo.new\n";
  void *vm = vm_open(boot);
  if (!vm) { printf("FAIL blocking_pop: vm_open returned NULL\n"); return 1; }
  char *out = vm_call(vm, "wait", "");
  int bad = (out == NULL) || (strstr(out, "pop:timeout") == NULL);
  printf("%s blocking_pop: wait -> %s\n", bad ? "FAIL" : "PASS", out ? out : "(null)");
  if (bad && out) printf("  (expected to contain: pop:timeout)\n");
  free(out);
  vm_close(vm);
  return bad;
}

/* Boot that raises before assigning $app: vm_call must say so in one line
 * (not raise NoMethodError-on-nil per call — a periodic tick would spam a
 * backtrace every call; observed live in the virtual-peripheral example). */
static int test_vm_call_nil_app(void) {
  const char *boot = "raise \"boot boom\"\n$app = 1\n";
  void *vm = vm_open(boot);
  if (!vm) { printf("FAIL nil_app: vm_open returned NULL\n"); return 1; }
  char *out = vm_call(vm, "anything", "");
  int bad = (out == NULL) || (strstr(out, "vm_call: $app is nil") == NULL) ||
            (strstr(out, "NoMethodError") != NULL);  /* the spam it replaces */
  printf("%s nil_app: -> %s", bad ? "FAIL" : "PASS", out ? out : "(null)\n");
  if (bad && out) printf("  (expected to contain: vm_call: $app is nil)\n");
  free(out);
  vm_close(vm);
  return bad;
}

static int test_persistent_vm(void) {
  const char *boot =
    "class Demo\n"
    "  def dispatch(a); print \"got:\"; print a; end\n"
    "end\n"
    "$app = Demo.new\n";
  void *vm = vm_open(boot);
  if (!vm) { printf("FAIL persistent: vm_open returned NULL\n"); return 1; }
  char *out = vm_call(vm, "dispatch", "hello");
  int bad = (out == NULL) || (strstr(out, "got:hello") == NULL);
  printf("%s persistent: dispatch -> %s\n", bad ? "FAIL" : "PASS", out ? out : "(null)");
  free(out);
  vm_close(vm);
  return bad;
}

int main(void) {
  int fails = 0;
  fails += check("puts",      "puts \"hello #{1+2}\"", "hello 3");
  fails += check("exception", "raise \"boom\"",        "boom");
  fails += check("syntax",    "1 +",                    "");  /* must not crash */
  fails += test_persistent_vm();
  fails += test_vm_call_blocking_pop();
  fails += test_vm_call_nil_app();
  if (fails) { printf("\n%d failure(s)\n", fails); return 1; }
  printf("\nall passed\n");
  return 0;
}
