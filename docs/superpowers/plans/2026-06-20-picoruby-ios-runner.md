# PicoRuby iOS Ruby-Runner Implementation Plan (R2P2-iOS)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up R2P2-iOS as a self-contained harness (parallel to R2P2-ESP32) whose `rake ios` fetches picoruby, cross-builds `libmruby.a` for the iOS Simulator, and builds+launches a SwiftUI app that runs Ruby (`app.rb`) and shows `puts` output — all headless.

**Architecture:** R2P2-iOS owns everything: its own picoruby fetch/build wrapper (`Rakefile`), an `MRuby::CrossBuild` config for the `iphonesimulator` SDK, a C bridge `picoruby_eval(const char*)` mirroring `picoruby-bin-picoruby`'s compile→task-run path with stdout/stderr capture, and a SwiftUI app generated from `project.yml` via xcodegen. No dependency on R2P2-macOS — the iOS axis (Xcode/xcodebuild/Simulator) is its own build system, like ESP-IDF is for R2P2-ESP32.

**Tech Stack:** picoruby (mruby VM + prism compiler, `mrc_*` C API), mruby build system (Rake), clang via `xcrun --sdk iphonesimulator`, xcodegen, xcodebuild, `simctl`, SwiftUI.

---

## Reference facts (verified against picoruby on 2026-06-20)

- Cross-build precedent: picoruby `build_config/r2p2-picoruby-pico2.rb` uses
  `MRuby::CrossBuild.new("name") { |conf| ... }` with `conf.cc.command` (target compiler)
  and `conf.cc.host_command` (host compiler for mrbc/compiler tools).
- Host-config defines to mirror: R2P2-macOS `build_config/r2p2-picoruby-darwin.rb`
  (MRB_INT64, MRB_NO_BOXING, MRB_UTF8_STRING, PICORB_ALLOC_ESTALLOC, PICORB_PLATFORM_*).
- Eval path (PICORB_VM_MRUBY), reachable with only `#include "picoruby.h"`:
  1. `mrc_ccontext *cc = mrc_ccontext_new(mrb);`
  2. `mrc_ccontext_filename(cc, "main");`
  3. `mrc_irep *irep = mrc_load_string_cxt(cc, &utf8, strlen(utf8));`  (NULL ⇒ compile error; diagnostics in `cc->diagnostic_list`)
  4. `mrb_value task = mrc_create_task(cc, irep, mrb_str_new_cstr(mrb,"main"), mrb_nil_value(), mrb_obj_value(mrb->top_self));`
  5. `mrb_task_run(mrb);` then check `mrb->exc` and `mrb_print_error(mrb)` (writes to stderr).
- VM open (avoid the `picorb_vm_init()` macro which references `vm`/`argv`):
  `mrb_state *mrb = mrb_open_with_custom_alloc(vm_heap, HEAP_SIZE);`

---

## File Structure

- Create `Rakefile` — picoruby fetch + ios/host build + xcodegen/xcodebuild/simctl.
- Create `.gitignore` — ignore `vendor/`, `build/`, `app/Vendor/`, `app/*.xcodeproj`.
- Create `CLAUDE.md` — repo identity (self-contained iOS harness, parallel to R2P2-ESP32).
- Create `build_config/r2p2-picoruby-ios-sim.rb` — iOS-simulator CrossBuild.
- Create `build_config/r2p2-picoruby-host.rb` — host build for the bridge smoke test.
- Create `bridge/picoruby_bridge.h` / `picoruby_bridge.c` / `smoke_test.c`.
- Create `app/project.yml`, `app/Sources/{App,ContentView}.swift`,
  `app/Sources/PicoRubyRunner-Bridging-Header.h`.
- Create `README.md` (final task).

---

## Task 0: Scaffold the self-contained repo

**Files:**
- Create: `Rakefile`, `.gitignore`, `CLAUDE.md`,
  `build_config/r2p2-picoruby-ios-sim.rb`, `build_config/r2p2-picoruby-host.rb`

- [ ] **Step 1: `.gitignore`**

```
# fetched picoruby tree (kept pristine; rebuilt via rake setup)
/vendor/
# build output
/build/
# staged lib + headers + generated project
/app/Vendor/
/app/*.xcodeproj
# process docs
/docs/superpowers/
```

- [ ] **Step 2: `CLAUDE.md`**

```markdown
## このリポジトリ

`R2P2-iOS` は picoruby を iOS（Xcode / xcodebuild / Simulator / 署名）という別建て
build system へ接続する自己完結 harness。R2P2-ESP32（ESP-IDF 軸）と並列の類型で、
薄い・transitional な R2P2-macOS とは異なり恒久的に独立する。R2P2-macOS には依存しない。

責務:
1. `rake check` で iOS build 前提（フル Xcode.app / iOS SDK / xcodegen）を verify
2. iOS 向け build config を保持（`build_config/r2p2-picoruby-ios-sim.rb`）
3. picoruby を `vendor/picoruby` に fetch し `MRUBY_BUILD_DIR=./build` で pristine に
   保ちながら iOS 向け `libmruby.a` を産出、C ブリッジ経由で SwiftUI アプリにリンク

依存 picoruby は `PICORUBY_REPO` / `PICORUBY_REF` で切替（default: upstream master）。
```

- [ ] **Step 3: `build_config/r2p2-picoruby-ios-sim.rb`**

```ruby
# iOS Simulator (arm64) cross-build for picoruby → libmruby.a for the
# iphonesimulator SDK. prism compiler + VM are baked in, so Ruby is compiled &
# run at runtime in-app. Mirrors the cross-build shape of picoruby's
# r2p2-picoruby-pico2.rb (target cc + host_command) and R2P2-macOS darwin defines.
# Gemboxes minimal (core + stdlib + compiler) — POSIX/shell/networking dropped.

sdk_path = `xcrun --sdk iphonesimulator --show-sdk-path`.strip
clang    = `xcrun --sdk iphonesimulator --find clang`.strip
ar       = `xcrun --sdk iphonesimulator --find ar`.strip
ios_min  = ENV["IOS_MIN"] || "17.0"

MRuby::CrossBuild.new("ios-sim") do |conf|
  conf.toolchain :clang

  conf.cc.command       = clang
  conf.linker.command   = clang
  conf.archiver.command = ar
  conf.cc.host_command  = "clang"   # builds mrbc / compiler for the host

  conf.cc.flags << "-arch" << "arm64"
  conf.cc.flags << "-isysroot" << sdk_path
  conf.cc.flags << "-mios-simulator-version-min=#{ios_min}"

  conf.cc.defines << "MRB_TICK_UNIT=4"
  conf.cc.defines << "MRB_TIMESLICE_TICK_COUNT=3"
  conf.cc.defines << "PICORB_ALLOC_ALIGN=8"
  conf.cc.defines << "PICORB_ALLOC_ESTALLOC"
  conf.cc.defines << "PICORB_PLATFORM_POSIX"
  conf.cc.defines << "PICORB_PLATFORM_DARWIN"
  conf.cc.defines << "MRB_INT64"
  conf.cc.defines << "MRB_NO_BOXING"
  conf.cc.defines << "MRB_UTF8_STRING"

  conf.picoruby

  conf.gem core: "mruby-compiler2"
  conf.gem core: "mruby-bin-mrbc2"
  conf.gem core: "picoruby-mruby"

  conf.gembox "core"
  conf.gembox "stdlib"
end
```

- [ ] **Step 4: `build_config/r2p2-picoruby-host.rb`**

Same defines/gemboxes as ios-sim but a plain host `MRuby::Build` (no `-arch`/`-isysroot`),
so `bridge/` can be smoke-tested fast on the host:

```ruby
# Host build matching the ios-sim gembox set, used only to link the bridge
# smoke test (bridge logic is target-independent).
MRuby::Build.new("host") do |conf|
  conf.toolchain :clang

  conf.cc.defines << "MRB_TICK_UNIT=4"
  conf.cc.defines << "MRB_TIMESLICE_TICK_COUNT=3"
  conf.cc.defines << "PICORB_ALLOC_ALIGN=8"
  conf.cc.defines << "PICORB_ALLOC_ESTALLOC"
  conf.cc.defines << "PICORB_PLATFORM_POSIX"
  conf.cc.defines << "PICORB_PLATFORM_DARWIN"
  conf.cc.defines << "MRB_INT64"
  conf.cc.defines << "MRB_NO_BOXING"
  conf.cc.defines << "MRB_UTF8_STRING"

  conf.picoruby

  conf.gem core: "mruby-compiler2"
  conf.gem core: "mruby-bin-mrbc2"
  conf.gem core: "picoruby-mruby"

  conf.gembox "core"
  conf.gembox "stdlib"
end
```

- [ ] **Step 5: `Rakefile`**

```ruby
require "shellwords"

ROOT          = __dir__
PICORUBY_REPO = ENV["PICORUBY_REPO"] || "https://github.com/picoruby/picoruby.git"
PICORUBY_REF  = ENV["PICORUBY_REF"]  || "master"
PICORUBY_SRC  = File.join(ROOT, "vendor", "picoruby")
BUILD_DIR     = File.join(ROOT, "build")
APP_DIR       = File.join(ROOT, "app")
VENDOR_DIR    = File.join(APP_DIR, "Vendor")
BUNDLE_ID     = "com.bash0c7.picoruby.PicoRubyRunner"

def mruby_env(cfg)
  { "MRUBY_BUILD_DIR" => BUILD_DIR, "MRUBY_CONFIG" => File.absolute_path(cfg) }
end

desc "Verify iOS build prerequisites"
task :check do
  if File.directory?("/Applications/Xcode.app") &&
     system("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path", out: File::NULL, err: File::NULL)
    puts "iOS SDK:    ok"
  else
    abort "iOS SDK:    missing — install full Xcode.app (App Store); CLT alone is not enough"
  end
  if system("which", "xcodegen", out: File::NULL, err: File::NULL)
    puts "xcodegen:   ok"
  else
    warn "xcodegen:   missing — run `brew install xcodegen`"
  end
end

desc "Fetch picoruby into vendor/picoruby"
task :setup do
  unless Dir.exist?(PICORUBY_SRC)
    sh "git clone --recursive --branch #{PICORUBY_REF.shellescape} " \
       "#{PICORUBY_REPO.shellescape} #{PICORUBY_SRC.shellescape}"
  end
end

desc "Re-fetch PICORUBY_REF into the existing vendor/picoruby"
task :refresh do
  raise "vendor/picoruby absent; run `rake setup`" unless Dir.exist?(PICORUBY_SRC)
  sh "git -C #{PICORUBY_SRC.shellescape} fetch #{PICORUBY_REPO.shellescape} #{PICORUBY_REF.shellescape}"
  sh "git -C #{PICORUBY_SRC.shellescape} checkout -B #{PICORUBY_REF.shellescape} FETCH_HEAD"
  sh "git -C #{PICORUBY_SRC.shellescape} submodule update --init --recursive"
end

namespace :ios do
  desc "Cross-build libmruby.a for the iOS Simulator and stage under app/Vendor"
  task lib: :setup do
    cfg = File.join(ROOT, "build_config", "r2p2-picoruby-ios-sim.rb")
    sh mruby_env(cfg), "cd #{PICORUBY_SRC.shellescape} && rake"
    lib = File.join(BUILD_DIR, "ios-sim", "lib", "libmruby.a")
    raise "expected #{lib} not found" unless File.file?(lib)
    rm_rf VENDOR_DIR
    mkdir_p File.join(VENDOR_DIR, "lib")
    mkdir_p File.join(VENDOR_DIR, "include")
    cp lib, File.join(VENDOR_DIR, "lib", "libmruby.a")
    cp_r File.join(PICORUBY_SRC, "include", "."), File.join(VENDOR_DIR, "include")
    puts "Staged libmruby.a + headers under #{VENDOR_DIR}"
  end

  desc "Generate the Xcode project from project.yml"
  task :gen do
    sh "cd #{APP_DIR.shellescape} && xcodegen generate"
  end

  desc "Build the app for the iOS Simulator"
  task :build do
    sh "xcodebuild -project #{File.join(APP_DIR, "PicoRubyRunner.xcodeproj").shellescape} " \
       "-scheme PicoRubyRunner -destination 'generic/platform=iOS Simulator' " \
       "-derivedDataPath #{File.join(ROOT, "build", "ios-app").shellescape} build"
  end

  desc "Boot a simulator, install, and launch the app"
  task :run do
    derived = File.join(ROOT, "build", "ios-app")
    app = Dir.glob(File.join(derived, "Build", "Products", "*-iphonesimulator", "PicoRubyRunner.app")).first
    raise "app not built; run `rake ios:build`" unless app
    udid = `xcrun simctl list devices available`.lines
           .grep(/iPhone/).first&.match(/\(([0-9A-F-]{36})\)/)&.captures&.first
    raise "no available iPhone simulator" unless udid
    sh "xcrun simctl boot #{udid} 2>/dev/null; true"
    sh "open -a Simulator"
    sh "xcrun simctl install #{udid} #{app.shellescape}"
    sh "xcrun simctl launch #{udid} #{BUNDLE_ID}"
  end

  desc "Full headless pipeline: lib -> gen -> build -> run"
  task all: [:lib, :gen, :build, :run]
end

desc "Build and launch the PicoRuby iOS Runner on the Simulator"
task ios: "ios:all"

namespace :host do
  desc "Host build of picoruby (for the bridge smoke test)"
  task lib: :setup do
    cfg = File.join(ROOT, "build_config", "r2p2-picoruby-host.rb")
    sh mruby_env(cfg), "cd #{PICORUBY_SRC.shellescape} && rake"
  end
end

desc "Compile + run the bridge smoke test on the host"
task smoke: "host:lib" do
  lib = File.join(BUILD_DIR, "host", "lib", "libmruby.a")
  out = "/tmp/picoruby_smoke"
  sh "clang -I #{File.join(PICORUBY_SRC, "include").shellescape} -I #{File.join(ROOT, "bridge").shellescape} " \
     "#{File.join(ROOT, "bridge", "smoke_test.c").shellescape} " \
     "#{File.join(ROOT, "bridge", "picoruby_bridge.c").shellescape} " \
     "#{lib.shellescape} -o #{out.shellescape}"
  sh out
end

desc "Remove build output (keeps vendor/picoruby)"
task :clean do
  rm_rf BUILD_DIR
  rm_rf VENDOR_DIR
end

desc "Remove build output and vendor/picoruby"
task clobber: :clean do
  rm_rf PICORUBY_SRC
end
```

- [ ] **Step 6: Verify rake loads and check runs**

Run: `rake -T && rake check`
Expected: task list prints (`ios`, `ios:lib`, `smoke`, `setup`, …); `check` prints
`iOS SDK: ok` and `xcodegen:` line (ok once `brew install xcodegen` done).

- [ ] **Step 7: Commit**

```bash
git add Rakefile .gitignore CLAUDE.md build_config/
git commit -m "feat: scaffold R2P2-iOS self-contained picoruby iOS harness

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 1: Build the iOS libmruby.a and verify it

Empirically closes the cross-build / host-tools / gembox risks.

- [ ] **Step 1: Build and stage the iOS lib**

Run: `rake ios:lib`
Expected: finishes with "Staged libmruby.a + headers under …/app/Vendor".

- [ ] **Step 2: Verify the archive targets the iOS Simulator**

Run:
```bash
file app/Vendor/lib/libmruby.a
lipo -info app/Vendor/lib/libmruby.a
```
Expected: `arm64` reported.

**Contingency (host-tools):** if the build fails because mrbc/compiler are built for the
iOS target, the `conf.cc.host_command` is insufficient — add an explicit
`MRuby::Build.new("host") { |c| c.toolchain :clang; c.picoruby; c.gembox "core" }` above
the CrossBuild in `r2p2-picoruby-ios-sim.rb` and re-run. **Contingency (gembox):** if a
gem in `core`/`stdlib` fails for iOS, drop it to the smallest set that builds and note it.

- [ ] **Step 3: Commit (only if the config needed contingency edits)**

```bash
git add build_config/r2p2-picoruby-ios-sim.rb
git commit -m "fix(ios): adjust ios-sim build config so libmruby.a links

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: C bridge `picoruby_eval` + host smoke test

**Files:**
- Create: `bridge/picoruby_bridge.h`, `bridge/picoruby_bridge.c`, `bridge/smoke_test.c`

- [ ] **Step 1: Bridge header**

Create `bridge/picoruby_bridge.h`:

```c
#ifndef PICORUBY_BRIDGE_H
#define PICORUBY_BRIDGE_H

/* Evaluate Ruby source. Returns captured stdout+stderr (including compile
 * diagnostics or an uncaught-exception backtrace) as a malloc'd C string.
 * The caller must free() it. Returns NULL only on VM-open failure. */
char *picoruby_eval(const char *src);

#endif /* PICORUBY_BRIDGE_H */
```

- [ ] **Step 2: Failing smoke test**

Create `bridge/smoke_test.c`:

```c
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
```

- [ ] **Step 3: Run smoke to verify it fails (no bridge impl yet)**

Run: `rake smoke`
Expected: link error — `picoruby_eval` undefined (bridge `.c` not written yet).

- [ ] **Step 4: Bridge implementation**

Create `bridge/picoruby_bridge.c`:

```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>

#if !defined(PICORB_PLATFORM_POSIX)
#define PICORB_PLATFORM_POSIX 1
#endif

#include "picoruby.h"
#include "picoruby_bridge.h"

#ifndef HEAP_SIZE
#define HEAP_SIZE (1024 * 2000)
#endif

static uint8_t vm_heap[HEAP_SIZE] __attribute__((aligned(16)));
mrb_state *global_mrb = NULL;

static void print_diagnostics(mrc_ccontext *cc) {
  mrc_diagnostic_list *d = cc->diagnostic_list;
  while (d) {
    fprintf(stderr, "main:%d:%d: %s\n", d->line, d->column, d->message);
    d = d->next;
  }
}

char *picoruby_eval(const char *src) {
  FILE *cap = tmpfile();
  if (cap == NULL) return NULL;
  fflush(stdout); fflush(stderr);
  int saved_out = dup(1), saved_err = dup(2);
  dup2(fileno(cap), 1);
  dup2(fileno(cap), 2);

  mrb_state *mrb = mrb_open_with_custom_alloc(vm_heap, HEAP_SIZE);
  global_mrb = mrb;
  if (mrb) {
    mrc_ccontext *cc = mrc_ccontext_new(mrb);
    mrc_ccontext_filename(cc, "main");
    const uint8_t *u = (const uint8_t *)src;
    mrc_irep *irep = mrc_load_string_cxt(cc, &u, strlen(src));
    if (irep == NULL) {
      print_diagnostics(cc);
    } else {
      mrb_value name = mrb_str_new_cstr(mrb, "main");
      mrb_value task = mrc_create_task(cc, irep, name,
                                       mrb_nil_value(),
                                       mrb_obj_value(mrb->top_self));
      if (!mrb_nil_p(task)) {
        mrb_task_run(mrb);
        if (mrb->exc) {
          mrb_print_error(mrb);
        }
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
```

- [ ] **Step 5: Run smoke to verify it passes**

Run: `rake smoke`
Expected: `PASS puts` (contains `hello 3`), `PASS exception` (contains `boom`), syntax
case does not crash, final line `all passed`.

**Contingency (missing symbols):** if `mrc_*`/`mrb_task_run` are unresolved at link, the
host gembox lacks the task scheduler — confirm `r2p2-picoruby-host.rb` includes the same
compiler gems as ios-sim. If an `mrc_*` decl is missing at compile, add the specific
`mrbgems/picoruby-mruby/include/...` header to the `-I` set in the `smoke` task.

- [ ] **Step 6: Commit**

```bash
git add bridge/
git commit -m "feat: picoruby_eval C bridge with stdout capture + host smoke test

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: SwiftUI app + xcodegen + headless run

**Files:**
- Create: `app/Sources/PicoRubyRunner-Bridging-Header.h`, `app/Sources/App.swift`,
  `app/Sources/ContentView.swift`, `app/project.yml`

- [ ] **Step 1: Bridging header**

Create `app/Sources/PicoRubyRunner-Bridging-Header.h`:

```c
#import "picoruby_bridge.h"
```

- [ ] **Step 2: App entry**

Create `app/Sources/App.swift`:

```swift
import SwiftUI

@main
struct PicoRubyRunnerApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

- [ ] **Step 3: UI (seeded with an app.rb that putses)**

Create `app/Sources/ContentView.swift`:

```swift
import SwiftUI

struct ContentView: View {
    @State private var source: String = "puts \"hello #{1 + 2}\""
    @State private var output: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PicoRuby Runner").font(.headline)
            TextEditor(text: $source)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 140)
                .border(.gray)
            Button("Run") { run() }
                .buttonStyle(.borderedProminent)
            Text("Output").font(.subheadline)
            ScrollView {
                Text(output.isEmpty ? "—" : output)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .border(.gray)
            Spacer()
        }
        .padding()
    }

    private func run() {
        guard let cstr = picoruby_eval(source) else {
            output = "(VM failed to start)"
            return
        }
        output = String(cString: cstr)
        free(cstr)
    }
}
```

- [ ] **Step 4: xcodegen spec**

Create `app/project.yml`:

```yaml
name: PicoRubyRunner
options:
  bundleIdPrefix: com.bash0c7.picoruby
  deploymentTarget:
    iOS: "17.0"
targets:
  PicoRubyRunner:
    type: application
    platform: iOS
    sources:
      - path: Sources
      - path: ../bridge
        includes:
          - "picoruby_bridge.c"
          - "picoruby_bridge.h"
    settings:
      base:
        SWIFT_OBJC_BRIDGING_HEADER: Sources/PicoRubyRunner-Bridging-Header.h
        HEADER_SEARCH_PATHS:
          - "$(SRCROOT)/Vendor/include"
          - "$(SRCROOT)/../bridge"
        LIBRARY_SEARCH_PATHS:
          - "$(SRCROOT)/Vendor/lib"
        OTHER_LDFLAGS:
          - "-lmruby"
        GENERATE_INFOPLIST_FILE: "YES"
        TARGETED_DEVICE_FAMILY: "1,2"
```

- [ ] **Step 5: Generate + build + run**

Run: `rake ios` (or `rake ios:gen ios:build ios:run`)
Expected: `xcodebuild` reports `** BUILD SUCCEEDED **`; Simulator opens; PicoRubyRunner
launches showing the "PicoRuby Runner" UI with the default snippet.

- [ ] **Step 6: Verify acceptance in the Simulator**

Tap Run with default `puts "hello #{1 + 2}"` → Output shows `hello 3`. Replace with
`raise "boom"` → Output contains `boom`, app stays alive.

- [ ] **Step 7: Commit**

```bash
git add app/
git commit -m "feat: SwiftUI Ruby-runner app wired to picoruby_eval via xcodegen

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: README

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write README**

Cover: what R2P2-iOS is (self-contained picoruby→iOS harness, parallel to R2P2-ESP32,
independent of R2P2-macOS); prerequisites (full Xcode.app, `brew install xcodegen`);
the one-command flow `rake ios`; what the app does (type Ruby / Run / see `puts` output);
and `rake smoke` for the host bridge test. Note BLE and device signing are out of scope
for now (follow-up).

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: README for R2P2-iOS picoruby Ruby-runner harness

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review notes

- **Spec coverage:** Rakefile + scaffold (Task 0) ↔ component 1; ios-sim config (Task 0/1)
  ↔ component 2; bridge (Task 2) ↔ component 3; app + project.yml (Task 3) ↔ component 4;
  README + check (Task 0/4) ↔ prerequisites. Acceptance (`hello 3`, `boom` survives,
  smoke) covered by Task 2 Step 5 and Task 3 Step 6.
- **Risks → tasks:** risk 1 (host tools) & 2 (gembox) closed by Task 1 Step 2 with
  contingencies; risk 3 (eval API) closed by Task 2 Step 5 against the real `mrc_*` symbols.
- **Type consistency:** `picoruby_eval(const char*) -> char*` identical across header,
  bridge, smoke test, bridging header, and Swift `run()`. Bundle id
  `com.bash0c7.picoruby.PicoRubyRunner` consistent between `project.yml` and `BUNDLE_ID`
  in the Rakefile.
- **Non-goals respected:** no networking/BLE/device-signing; Simulator-only
  (`generic/platform=iOS Simulator`), free-Apple-ID path. The R2P2 shell on iOS is a
  natural follow-up (the lib already contains the shell gems) but out of this MVP.
```
