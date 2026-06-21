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
  if (fails) { printf("\n%d failure(s)\n", fails); return 1; }
  printf("\nall passed\n");
  return 0;
}
