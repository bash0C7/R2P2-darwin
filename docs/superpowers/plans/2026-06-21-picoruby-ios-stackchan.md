# PicoRuby iOS Core + Stack-chan Controller — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor R2P2-iOS into a reusable PicoRuby-on-iOS core (persistent-VM bridge + examples/ layering + on-device signed builds) and add a Guideline-2.5.2-free Stack-chan BLE controller as the first real example, with the control logic written in Ruby.

**Architecture:** A generalized C bridge exposes both `repl_eval` (fresh VM per call) and a persistent-VM API (`vm_open`/`vm_call`/`vm_close`). Examples live under `examples/` and consume the core. The Stack-chan example bundles a fixed `app.rb` that reuses the PC CLI's pure-Ruby frame codec and drives BLE through an iOS-adapted picoruby-ble (Swift/CoreBluetooth backend). A single VM-owner thread drains a command queue and pumps BLE events.

**Tech Stack:** picoruby (mruby VM + prism + mruby-task), C bridge, SwiftUI, xcodegen, CoreBluetooth (Swift), Rake.

**Spec:** `docs/superpowers/specs/2026-06-21-picoruby-ios-stackchan-design.md`

**Phasing note:** Phase 1 below is fully specified and execution-ready. Phases 2–4 each begin with a discovery task that records exact, currently-unknown facts (signing flow, picoruby-ble API signatures, frame_codec internals); the remaining steps of each phase are finalized JIT at the start of that phase, once the discovery task has recorded the facts. This avoids inventing APIs. Re-invoke writing-plans at each phase boundary to expand it.

---

## File Structure (all phases)

- `bridge/picoruby_bridge.{c,h}` — core VM bridge. `repl_eval` (rename of `picoruby_eval`) + new `vm_open`/`vm_call`/`vm_close`. One responsibility: embed and drive the mruby VM, capture output.
- `bridge/task_hal_ios.c` — polling task HAL (unchanged).
- `bridge/smoke_test.c` — host test harness for the bridge (repl + persistent VM).
- `build_config/r2p2-picoruby-ios-sim.rb` — iphonesimulator cross-build (existing).
- `build_config/r2p2-picoruby-ios-device.rb` — iphoneos arm64 device cross-build (new, Phase 2).
- `build_config/r2p2-picoruby-host.rb` — host build for smoke (existing; grows to include picoruby-ble in Phase 3).
- `Rakefile` — adds `ios:device:*` tasks (Phase 2) and example-path parametrization (Phase 1).
- `examples/repl/` — moved from `app/`; the REPL ("test版"), wired to `repl_eval`.
- `examples/stackchan/` — new; SwiftUI buttons, bundled `app.rb`, picoruby-ble.
- `vendor/picoruby-ble/` — iOS-adapted port (Phase 3; vendored, gitignored).

---

## Phase 1 — Core refactor: persistent-VM bridge + examples/ layering

Produces working software: REPL still builds and runs from its new path; the persistent-VM API is host-verified.

### Task 1: Rename `picoruby_eval` → `repl_eval`

Pure rename, no behavior change. Establishes the core naming from the spec.

**Files:**
- Modify: `bridge/picoruby_bridge.h`
- Modify: `bridge/picoruby_bridge.c:37` (function definition)
- Modify: `bridge/smoke_test.c` (all call sites)
- Modify: `app/Sources/ContentView.swift` (the `picoruby_eval` call)
- Modify: `app/Sources/PicoRubyRunner-Bridging-Header.h` (if it declares the symbol)

- [ ] **Step 1: Update the header**

In `bridge/picoruby_bridge.h`, rename the declaration:

```c
/* Evaluate Ruby source in a fresh, single-use VM. Returns captured
 * stdout+stderr (including compile diagnostics or an uncaught-exception
 * backtrace) as a malloc'd C string. The caller must free() it. Returns NULL
 * only on allocation/setup failure (out of memory, or tmpfile() failure). */
char *repl_eval(const char *src);
```

- [ ] **Step 2: Update the implementation**

In `bridge/picoruby_bridge.c`, change the function name on the definition line from `char *picoruby_eval(const char *src) {` to `char *repl_eval(const char *src) {`. Leave the body unchanged.

- [ ] **Step 3: Update all callers**

Replace `picoruby_eval(` with `repl_eval(` in `bridge/smoke_test.c`, `app/Sources/ContentView.swift`, and `app/Sources/PicoRubyRunner-Bridging-Header.h` (only if the symbol is declared there).

- [ ] **Step 4: Run the host smoke test to verify no behavior change**

Run: `rake smoke`
Expected: PASS for puts/exception/syntax, ending "all passed".

- [ ] **Step 5: Commit**

```bash
git add bridge/ app/Sources/
git commit -m "refactor(bridge): rename picoruby_eval to repl_eval"
```

### Task 2: Add the persistent-VM API (`vm_open`/`vm_call`/`vm_close`)

A long-lived VM that loads a boot Ruby source once and answers many calls. All `mrb_*` happen on the caller's single thread (the future agent thread). The boot source defines classes and assigns a dispatcher object to the global `$app`; `vm_call` invokes a method on `$app`.

**Files:**
- Modify: `bridge/picoruby_bridge.h`
- Modify: `bridge/picoruby_bridge.c`
- Modify: `bridge/smoke_test.c` (add a persistent-VM test)

- [ ] **Step 1: Write the failing host test**

Append to `bridge/smoke_test.c` a test and call it from `main` before the final summary:

```c
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
```

Add `failures += test_persistent_vm();` alongside the existing test calls in `main` (match the existing accumulation pattern in the file).

- [ ] **Step 2: Run the test to verify it fails to compile/link**

Run: `rake smoke`
Expected: FAIL — link error "undefined symbols: vm_open, vm_call, vm_close".

- [ ] **Step 3: Declare the API in the header**

Add to `bridge/picoruby_bridge.h` before the closing `#endif`:

```c
/* Persistent VM. vm_open allocates a heap, opens a VM, and runs boot_src
 * (which should define classes and assign a dispatcher object to the global
 * $app). Returns an opaque handle, or NULL on failure. vm_call invokes
 * `method` on $app with a single String argument `arg`, returning captured
 * stdout+stderr as a malloc'd string the caller must free() (NULL on setup
 * failure). vm_close tears the VM down. All three MUST be called from one
 * thread. */
void *vm_open(const char *boot_src);
char *vm_call(void *vm, const char *method, const char *arg);
void  vm_close(void *vm);
```

- [ ] **Step 4: Implement the persistent VM**

Add to `bridge/picoruby_bridge.c` (reusing the file's existing fd-capture idiom and the `mrc_*` compile path used by `repl_eval`):

```c
typedef struct { mrb_state *mrb; uint8_t *heap; } vm_handle;

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

void *vm_open(const char *boot_src) {
  uint8_t *heap = (uint8_t *)calloc(1, HEAP_SIZE);
  if (heap == NULL) return NULL;
  mrb_state *mrb = mrb_open_with_custom_alloc(heap, HEAP_SIZE);
  if (mrb == NULL) { free(heap); return NULL; }
  global_mrb = mrb;
  /* prepend the same puts shim repl_eval uses */
  size_t shim_len = strlen(PUTS_SHIM), src_len = strlen(boot_src);
  char *combined = (char *)malloc(shim_len + src_len + 1);
  if (combined == NULL) { mrb_close(mrb); global_mrb = NULL; free(heap); return NULL; }
  memcpy(combined, PUTS_SHIM, shim_len);
  memcpy(combined + shim_len, boot_src, src_len + 1);
  mrc_ccontext *cc = mrc_ccontext_new(mrb);
  mrc_ccontext_filename(cc, "main");
  const uint8_t *u = (const uint8_t *)combined;
  mrc_irep *irep = mrc_load_string_cxt(cc, &u, strlen(combined));
  if (irep == NULL) { print_diagnostics(cc); }
  else { run_irep(mrb, cc, irep); }
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
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `rake smoke`
Expected: PASS including "PASS persistent: dispatch -> got:hello", ending "all passed".

- [ ] **Step 6: Commit**

```bash
git add bridge/
git commit -m "feat(bridge): persistent VM API (vm_open/vm_call/vm_close)"
```

### Task 3: Move `app/` → `examples/repl/` and parametrize Rakefile

**Files:**
- Move: `app/` → `examples/repl/` (git mv)
- Modify: `Rakefile` (APP_DIR/VENDOR_DIR → example-relative)
- Modify: `examples/repl/project.yml` (paths to bridge/ if relative)

- [ ] **Step 1: Move the app directory**

```bash
git mv app examples/repl
```

- [ ] **Step 2: Parametrize the Rakefile example path**

In `Rakefile`, replace the `APP_DIR` definition and dependents so the active example is selectable, defaulting to repl:

```ruby
EXAMPLE    = ENV["EXAMPLE"] || "repl"
APP_DIR    = File.join(ROOT, "examples", EXAMPLE)
VENDOR_DIR = File.join(APP_DIR, "Vendor")
```

Leave the rest of the tasks unchanged (they already reference `APP_DIR`/`VENDOR_DIR`).

- [ ] **Step 3: Fix any relative paths in the moved project.yml**

In `examples/repl/project.yml`, adjust any `../` paths to `bridge/`, `Vendor/`, or sources so they resolve from `examples/repl/`. (The bridge lives at repo-root `bridge/`, now two levels up: `../../bridge/...`.)

- [ ] **Step 4: Verify the REPL still generates and builds for the Simulator**

Run: `rake ios:lib ios:gen ios:build`
Expected: `libmruby.a` staged under `examples/repl/Vendor`, xcodegen succeeds, xcodebuild succeeds.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: move REPL app to examples/repl, parametrize EXAMPLE"
```

### Phase 1 verification gate

- [ ] `rake smoke` passes (repl + persistent VM).
- [ ] `EXAMPLE=repl rake ios` builds and launches the REPL on the Simulator and prints `hello 3` (the existing happy-path check from HANDOFF.md).

Note: the spec mentioned a throwaway GUI persistent-VM example for Phase 1 verification; the host smoke test for `vm_*` covers this without a disposable app (YAGNI), and the Stack-chan example becomes the first GUI consumer of the persistent VM in Phase 4.

---

## Phase 2 — On-device build + free Personal Team signing (core capability)

Opens with discovery, then becomes execution-ready.

### Task 2.0 (discovery): Record the exact device build + signing facts

- [ ] Read `build_config/r2p2-picoruby-ios-sim.rb` in full and record every directive that is SDK-specific (the `xcrun --sdk iphonesimulator` invocation, arch flags, min-version flag) so the device variant changes ONLY the SDK/arch/min-version and nothing ABI-related.
- [ ] Record from `examples/repl/project.yml` the current `settings`/`GCC_PREPROCESSOR_DEFINITIONS` block verbatim (the ABI defines that must be preserved).
- [ ] Determine the device install/launch command available on this machine: check `xcrun devicectl --version` and `xcrun devicectl device list`. Record the exact `devicectl device install app` / `process launch` syntax.
- [ ] Record the user's free Personal Team id (the human signs into Xcode once and selects the team; capture the resulting `DEVELOPMENT_TEAM` value from the generated project, or have the user provide it).

Then expand Phase 2 tasks (device build_config, `ios:device:lib/build/run` rake tasks, signed project.yml settings) with concrete code using the recorded facts, and re-run the writing-plans self-review.

**Human-only step (cannot be automated):** connect+trust the iPhone; sign into the Apple ID and select the Personal Team in Xcode once. Free Personal Team builds expire after 7 days.

**Phase 2 verification gate:** `EXAMPLE=repl rake ios:device:build` produces a signed `.app`; it installs and launches on the connected iPhone and prints `hello 3`.

---

## Phase 3 — picoruby-ble iOS adaptation (the glue)

### Task 3.0 (discovery): Record the exact picoruby-ble facts

- [ ] Vendor the port: clone `picoruby-ble-darwin-port` into `vendor/picoruby-ble/` (gitignored) or add as a fetch step in the Rakefile mirroring the picoruby fetch.
- [ ] Read and record the EXACT central Ruby API signatures from `mrbgems/picoruby-ble/mrblib/ble_central.rb` and `ble.rb`: the constructor, `scan`, `connect`, how `@services`/characteristics are represented, the precise `write_value_of_characteristic_without_response` signature (arg order/types), how to resolve a characteristic's value_handle from a UUID, how notifications/ACKs surface (event constants), and the `start(timeout_ms)` loop contract.
- [ ] Read `ports/darwin/ext/Package.swift` and `mrbgems/picoruby-ble/mrbgem.rake`; record the `build.darwin?` gate, the Swift product name, and the `@c` export header location.
- [ ] Confirm picoruby-ble's gem dependency closure contains nothing POSIX/IO that broke the iOS link before (cross-check against the reduced gem set in `r2p2-picoruby-ios-sim.rb`).

Then expand Phase 3: `Package.swift` iOS platform line; gembox addition of picoruby-ble to both ios build_configs and the host config; xcodegen wiring to compile `PicoBLEDarwin` Swift sources into the (stackchan) app target; `NSBluetoothCentralManagerUsageDescription` in Info.plist; a minimal scan-only example to verify discovery. Finalize code from the recorded signatures; re-run self-review.

**Phase 3 verification gate:** the host build links with picoruby-ble; a minimal iOS example builds for device and, on the physical iPhone, scans and discovers the `StackChan-PicoRuby` peripheral (manual).

---

## Phase 4 — Stack-chan controller example

### Task 4.0 (discovery): Record the frame_codec internals

- [ ] Read `stackchan-picoruby/pc/stackchan/lib/stackchan/ble/{frame_codec,send_builder,face_table,led_color_table}.rb` in full. Record the exact public methods, their inputs/outputs, and every Ruby feature they use (string interpolation, `sprintf`/`%`, `Hash`, `Array`, `Comparable`, etc.).
- [ ] For each feature, confirm it exists in the reduced iOS VM (cross-check the gem set). Record any feature that is absent and the minimal rewrite/port to make the codec run unchanged otherwise.

Then expand Phase 4 with concrete code:
- `examples/stackchan/app.rb` — vendor the codec files (verbatim or with the recorded minimal edits) and a `Stackchan` class with `face/led/head/torque` building frames via the codec and writing to NUS RX over picoruby-ble; bind NUS service/RX/TX after connect; subscribe TX for ACK `.`/`?` and `<touch:zone>\n`; a main loop draining the Swift command queue and pumping BLE events (the §E agent thread).
- `examples/stackchan/project.yml` + SwiftUI: Connect button (scan name prefix `StackChan-PicoRuby`), connection-state display, face/LED/head/torque buttons that enqueue commands, the command queue + VM-owner background thread, BLE usage string.
- Host smoke additions asserting the codec emits `<F:2>\n`, `<L:1,...>\n`, `<YL:50,T:500>\n`, torque frames (reuse `pc/stackchan/test/test_ble_*.rb` expectations).
- Re-run self-review.

**Phase 4 verification gate (manual, requires physical Stack-chan + iPhone):** Connect, then each button visibly drives the robot (face change, LED, head movement after torque on), with the ACK path observed. The host smoke asserts correct frame encoding.

---

## Spec coverage check

- Core: persistent-VM bridge (Task 2), examples/ layering (Task 3), Swift↔Ruby glue pattern (Phase 3 wiring), two SDK cross-builds (sim existing; device Phase 2). ✓
- Stack-chan example: app.rb reusing codec (Phase 4), connect UX (Phase 4), command-queue concurrency (Phase 4). ✓
- picoruby-ble iOS adaptation (Phase 3). ✓
- On-device build + signing (Phase 2). ✓
- 2.5.2: satisfied by design (bundled fixed Ruby, no REPL in the stackchan app) — no code task needed; the REPL's user-input surface stays isolated in examples/repl. ✓
- Testing: host smoke for repl + persistent VM (Phase 1) and codec frames (Phase 4); manual BLE gates (Phases 3–4). ✓
