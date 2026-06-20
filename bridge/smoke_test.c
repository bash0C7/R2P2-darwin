#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "picoruby_bridge.h"

static int check(const char *label, const char *src, const char *needle) {
  char *out = picoruby_eval(src);
  if (out == NULL) { printf("FAIL %s: NULL\n", label); return 1; }
  int ok = strstr(out, needle) != NULL;
  printf("%s %s: %s", ok ? "PASS" : "FAIL", label, out);
  if (!ok) printf("  (expected to contain: %s)\n", needle);
  free(out);
  return ok ? 0 : 1;
}

int main(void) {
  int fails = 0;
  fails += check("puts",      "puts \"hello #{1+2}\"", "hello 3");
  fails += check("exception", "raise \"boom\"",        "boom");
  fails += check("syntax",    "1 +",                    "");  /* must not crash */
  if (fails) { printf("\n%d failure(s)\n", fails); return 1; }
  printf("\nall passed\n");
  return 0;
}
