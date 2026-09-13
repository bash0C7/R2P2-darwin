# iPhone Torch Example Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A minimal iOS example where Ruby (PicoRuby in-app) turns the iPhone torch on/off via two buttons, driving `AVCaptureDevice` through a new local `picoruby-iphone-torch` gem's Darwin port.

**Architecture:** Mirror the `virtual-peripheral` example. A new local mrbgem provides a `Torch` class whose `on`/`off`/`available?` methods (C, in `src/mruby/torch.c`) call a port ABI (`include/torch.h`); the Darwin port (`ports/darwin/torch.c`) delegates to a Swift `PicoTorchDarwin` package that calls `AVCaptureDevice`. The SwiftUI app boots a persistent VM with `app.rb` (defines `$app = TorchApp.new`) and each button calls `vm_call(vm, "on"/"off", "")`. No poll timer (torch is fire-and-forget).

**Tech Stack:** PicoRuby (mruby VM + prism), C mrbgem, Swift Package (AVFoundation), Xcode/xcodegen, Rake cross-build to `libmruby.a`.

**Spec:** `docs/superpowers/specs/2026-06-22-iphone-torch-example-design.md`

---

## File Structure

```
examples/iphone-torch/
  picoruby-iphone-torch/
    mrbgem.rake                                  # gem spec (no deps)
    include/torch.h                              # port ABI
    src/torch.c                                  # VM dispatch
    src/mruby/torch.c                            # mruby C ext: class Torch
    ports/darwin/torch.c                         # ABI -> Swift ptorch_*
    ports/darwin/ext/
      Package.swift                              # PicoTorchDarwin dynamic lib
      Sources/PicoTorchDarwin/PicoTorchExports.swift
  app.rb                                         # $app = TorchApp.new
  Sources/
    App.swift
    ContentView.swift                            # ON / OFF buttons + log
    VMExecutor.swift                             # vm_open + call (no timer)
    Torch-Bridging-Header.h
  project.yml
  README.md

build_config/
  r2p2-picoruby-ios-torch-sim.rb
  r2p2-picoruby-ios-torch-device.rb

Rakefile                                         # add namespace :torch
```

Plans and specs live under `docs/superpowers/` which is gitignored in this repo (process docs kept local). Commit only the example/gem/build_config/Rakefile/README changes.

---

## Conventions confirmed from the existing codebase

- Gem build auto-compiles `src/*.c` (top-level only — `src/torch.c` `#include`s the VM-specific file), `mrblib/**/*.rb`, and the first matching `ports/<port>/*.c` selected by `conf.ports`.
- The gem's own `include/` is added to the C include path; `src/torch.c` includes the ABI via `../include/torch.h`.
- Gem init symbol convention: `picoruby-ble` → `mrb_picoruby_ble_gem_init`. So `picoruby-iphone-torch` → `mrb_picoruby_iphone_torch_gem_init`.
- Custom presym symbols (`MRB_SYM(Torch)`, `MRB_SYM(on)`, …) are collected by the build-time presym scan over the gem's C sources — no manual registration.
- Swift C-exports use `@c public func` (SE-0495), NOT `@_cdecl`, matching `PicoBLEExports.swift`.
- The Darwin port C declares the Swift symbols as plain `extern` (no generated `-Swift.h`), so the cross-build never runs `swift build`.
- ABI defines that MUST appear in `project.yml` (build-wide trap — reviewers falsely flag these; they are required): `MRB_CONSTRAINED_BASELINE_PROFILE=1`, `MRB_HEAP_PAGE_SIZE=128`, plus the set copied from `virtual-peripheral/project.yml`.

---

## Task 1: Create the gem C/ABI skeleton

**Files:**
- Create: `examples/iphone-torch/picoruby-iphone-torch/mrbgem.rake`
- Create: `examples/iphone-torch/picoruby-iphone-torch/include/torch.h`
- Create: `examples/iphone-torch/picoruby-iphone-torch/src/torch.c`
- Create: `examples/iphone-torch/picoruby-iphone-torch/src/mruby/torch.c`
- Create: `examples/iphone-torch/picoruby-iphone-torch/ports/darwin/torch.c`

- [ ] **Step 1: Write `mrbgem.rake`**

```ruby
MRuby::Gem::Specification.new('picoruby-iphone-torch') do |spec|
  spec.license = 'MIT'
  spec.author  = 'bash0C7'
  spec.summary = 'Control the iPhone camera torch (flashlight) from Ruby'
  # No add_dependency: the Darwin port references only its own Swift backend,
  # resolved at app link time. No mbedtls/cyw43/rp2040 transitive deps.
end
```

- [ ] **Step 2: Write `include/torch.h` (the port ABI — identical across any future port)**

```c
#ifndef PICORUBY_TORCH_H
#define PICORUBY_TORCH_H

#include <stdbool.h>

/* Turn the device torch on (true) or off (false). Returns true on success,
 * false if the device has no controllable torch (e.g. the Simulator). */
bool TORCH_set(bool on);

/* True if this device exposes a controllable torch. */
bool TORCH_available(void);

#endif /* PICORUBY_TORCH_H */
```

- [ ] **Step 3: Write `src/torch.c` (VM dispatch — mirrors `src/ble.c`)**

```c
#include <stdbool.h>
#include "picoruby.h"
#include "../include/torch.h"

#if defined(PICORB_VM_MRUBY)

#include "mruby/torch.c"

#endif
```

- [ ] **Step 4: Write `src/mruby/torch.c` (mruby C extension defining `class Torch`)**

```c
#include "mruby.h"
#include "mruby/presym.h"

static mrb_value
mrb_torch_on(mrb_state *mrb, mrb_value self)
{
  return mrb_bool_value(TORCH_set(true));
}

static mrb_value
mrb_torch_off(mrb_state *mrb, mrb_value self)
{
  return mrb_bool_value(TORCH_set(false));
}

static mrb_value
mrb_torch_available_p(mrb_state *mrb, mrb_value self)
{
  return mrb_bool_value(TORCH_available());
}

void
mrb_picoruby_iphone_torch_gem_init(mrb_state *mrb)
{
  struct RClass *class_Torch = mrb_define_class_id(mrb, MRB_SYM(Torch), mrb->object_class);
  mrb_define_method_id(mrb, class_Torch, MRB_SYM(on),  mrb_torch_on,  MRB_ARGS_NONE());
  mrb_define_method_id(mrb, class_Torch, MRB_SYM(off), mrb_torch_off, MRB_ARGS_NONE());
  mrb_define_method_id(mrb, class_Torch, MRB_SYM_Q(available), mrb_torch_available_p, MRB_ARGS_NONE());
}

void
mrb_picoruby_iphone_torch_gem_final(mrb_state *mrb)
{
}
```

Note: `TORCH_set`/`TORCH_available` are declared by `../include/torch.h`, which `src/torch.c` includes before `#include "mruby/torch.c"`.

- [ ] **Step 5: Write `ports/darwin/torch.c` (Darwin port → Swift)**

```c
#include "../../include/torch.h"

/* Provided by the PicoTorchDarwin Swift package (@c exports), resolved at app
 * link time. Declared here so the cross-build needs no generated -Swift.h. */
extern int ptorch_set(int on);
extern int ptorch_available(void);

bool
TORCH_set(bool on)
{
  return ptorch_set(on ? 1 : 0) != 0;
}

bool
TORCH_available(void)
{
  return ptorch_available() != 0;
}
```

- [ ] **Step 6: Commit**

```bash
git add examples/iphone-torch/picoruby-iphone-torch
git commit -m "feat(iphone-torch): gem C skeleton — Torch class, port ABI, Darwin port"
```

---

## Task 2: Create the Swift backend (PicoTorchDarwin)

**Files:**
- Create: `examples/iphone-torch/picoruby-iphone-torch/ports/darwin/ext/Package.swift`
- Create: `examples/iphone-torch/picoruby-iphone-torch/ports/darwin/ext/Sources/PicoTorchDarwin/PicoTorchExports.swift`
- Create: `examples/iphone-torch/picoruby-iphone-torch/ports/darwin/ext/.gitignore`

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version:6.3
import PackageDescription

// picoruby-iphone-torch Darwin backend. A dynamic library whose @c exports
// (ptorch_*) the port C calls. Linked into the APP target by project.yml.
let package = Package(
  name: "PicoTorchDarwin",
  platforms: [.iOS(.v13), .macOS(.v11)],
  products: [
    .library(name: "PicoTorchDarwin", type: .dynamic, targets: ["PicoTorchDarwin"]),
  ],
  targets: [
    .target(name: "PicoTorchDarwin", path: "Sources/PicoTorchDarwin"),
  ]
)
```

- [ ] **Step 2: Write `Sources/PicoTorchDarwin/PicoTorchExports.swift`**

```swift
import AVFoundation

// C-callable surface for ports/darwin/torch.c. Uses `@c` (SE-0495) like
// PicoBLEExports. Direction is C -> Swift only.

@c public func ptorch_set(_ on: Int32) -> Int32 {
  guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else {
    return 0
  }
  do {
    try device.lockForConfiguration()
    device.torchMode = (on != 0) ? .on : .off
    device.unlockForConfiguration()
    return 1
  } catch {
    return 0
  }
}

@c public func ptorch_available() -> Int32 {
  (AVCaptureDevice.default(for: .video)?.hasTorch ?? false) ? 1 : 0
}
```

- [ ] **Step 3: Write `.gitignore` (ignore SwiftPM build output)**

```
.build/
```

- [ ] **Step 4: Verify the Swift package compiles (host sanity check)**

Run: `cd examples/iphone-torch/picoruby-iphone-torch/ports/darwin/ext && swift build -c release`
Expected: `Build complete!` (it builds for macOS host; AVFoundation is available there too). If `@c` is rejected by the installed toolchain, fall back to `@_cdecl` and confirm `PicoBLEExports.swift` still builds with `@c` — match whichever the toolchain accepts. Then `git -C ... checkout` nothing; just remove `.build/`.

- [ ] **Step 5: Commit**

```bash
git add examples/iphone-torch/picoruby-iphone-torch/ports/darwin/ext
git commit -m "feat(iphone-torch): PicoTorchDarwin Swift backend (AVCaptureDevice torch)"
```

---

## Task 3: Build configs + Rake cross-build

**Files:**
- Create: `build_config/r2p2-picoruby-ios-torch-sim.rb`
- Create: `build_config/r2p2-picoruby-ios-torch-device.rb`
- Modify: `Rakefile` (add `namespace :torch` under `namespace :ios`)

- [ ] **Step 1: Write `build_config/r2p2-picoruby-ios-torch-sim.rb`**

Copy `build_config/r2p2-picoruby-ios-sim.rb` verbatim, change the build name to `ios-torch-sim`, and append the gem + port selection before the closing `end`.

```ruby
# iOS Simulator (arm64) cross-build for the iPhone Torch example: the bare picoruby
# VM/compiler (identical to r2p2-picoruby-ios-sim.rb) PLUS the local
# picoruby-iphone-torch gem built with its Darwin port. EXAMPLE-SCOPED — the base
# sim config stays torch-free so the REPL keeps linking standalone.
#
# The Darwin port (ports/darwin/torch.c) references only ptorch_* (provided by the
# PicoTorchDarwin Swift package at APP link time), so it pulls no extra gem deps.
# pble-style mbedtls/cyw43 dependency stripping and the darwin? monkeypatch are NOT
# needed here: this gem declares no add_dependency and its mrbgem.rake never calls
# build.darwin?.

sdk_path = `xcrun --sdk iphonesimulator --show-sdk-path`.strip
clang    = `xcrun --sdk iphonesimulator --find clang`.strip
ar       = `xcrun --sdk iphonesimulator --find ar`.strip
ios_min  = ENV["IOS_MIN"] || "17.0"

MRuby::CrossBuild.new("ios-torch-sim") do |conf|
  conf.toolchain :clang

  conf.linker.libraries.delete("m")

  conf.cc.command       = clang
  conf.linker.command   = clang
  conf.archiver.command = ar
  conf.cc.host_command  = "clang"

  conf.cc.flags << "-arch" << "arm64"
  conf.cc.flags << "-isysroot" << sdk_path
  conf.cc.flags << "-mios-simulator-version-min=#{ios_min}"

  conf.cc.defines << "MRB_TICK_UNIT=4"
  conf.cc.defines << "MRB_TIMESLICE_TICK_COUNT=3"
  conf.cc.defines << "PICORB_ALLOC_ALIGN=8"
  conf.cc.defines << "PICORB_ALLOC_ESTALLOC"
  conf.cc.defines << "PICORB_PLATFORM_DARWIN"
  conf.cc.defines << "MRB_INT64"
  conf.cc.defines << "MRB_NO_BOXING"
  conf.cc.defines << "MRB_UTF8_STRING"

  conf.picoruby

  conf.gem core: "mruby-compiler2"

  # --- iPhone Torch: local picoruby-iphone-torch gem + its Darwin port -----------
  conf.ports :darwin
  conf.gem File.expand_path("../examples/iphone-torch/picoruby-iphone-torch", __dir__)
end
```

- [ ] **Step 2: Write `build_config/r2p2-picoruby-ios-torch-device.rb`**

Identical to Step 1 but for the device SDK: copy `r2p2-picoruby-ios-device.rb`'s SDK lines and use build name `ios-torch-device`.

```ruby
# iOS device (arm64) cross-build for the iPhone Torch example. See
# r2p2-picoruby-ios-torch-sim.rb for the example-scoped rationale; this is the
# iphoneos-SDK twin.

sdk_path = `xcrun --sdk iphoneos --show-sdk-path`.strip
clang    = `xcrun --sdk iphoneos --find clang`.strip
ar       = `xcrun --sdk iphoneos --find ar`.strip
ios_min  = ENV["IOS_MIN"] || "17.0"

MRuby::CrossBuild.new("ios-torch-device") do |conf|
  conf.toolchain :clang

  conf.linker.libraries.delete("m")

  conf.cc.command       = clang
  conf.linker.command   = clang
  conf.archiver.command = ar
  conf.cc.host_command  = "clang"

  conf.cc.flags << "-arch" << "arm64"
  conf.cc.flags << "-isysroot" << sdk_path
  conf.cc.flags << "-miphoneos-version-min=#{ios_min}"

  conf.cc.defines << "MRB_TICK_UNIT=4"
  conf.cc.defines << "MRB_TIMESLICE_TICK_COUNT=3"
  conf.cc.defines << "PICORB_ALLOC_ALIGN=8"
  conf.cc.defines << "PICORB_ALLOC_ESTALLOC"
  conf.cc.defines << "PICORB_PLATFORM_DARWIN"
  conf.cc.defines << "MRB_INT64"
  conf.cc.defines << "MRB_NO_BOXING"
  conf.cc.defines << "MRB_UTF8_STRING"

  conf.picoruby

  conf.gem core: "mruby-compiler2"

  conf.ports :darwin
  conf.gem File.expand_path("../examples/iphone-torch/picoruby-iphone-torch", __dir__)
end
```

- [ ] **Step 3: Add the `:torch` namespace to `Rakefile`**

Insert this block inside `namespace :ios do ... end`, modeled on `namespace :vperiph` but without the timer/central-helper tasks. Place it right after the `namespace :vperiph do ... end` block.

```ruby
  namespace :torch do
    TORCH_DIR     = File.join(ROOT, "examples", "iphone-torch")
    TORCH_PROJ    = File.join(TORCH_DIR, "Torch.xcodeproj")
    TORCH_BUNDLE  = "com.bash0c7.picoruby.Torch"
    TORCH_VENDOR  = File.join(TORCH_DIR, "Vendor")
    TORCH_DERIVED = File.join(ROOT, "build", "ios-torch-app")
    TORCH_DEVICE_DERIVED = File.join(ROOT, "build", "ios-torch-app-device")

    desc "Cross-build libmruby.a (Simulator) WITH picoruby-iphone-torch and stage under examples/iphone-torch/Vendor"
    task lib: :setup do
      stage_libmruby("r2p2-picoruby-ios-torch-sim.rb", "ios-torch-sim", TORCH_VENDOR)
    end

    desc "Generate the Torch Xcode project from project.yml"
    task :gen do
      sh "cd #{TORCH_DIR.shellescape} && xcodegen generate"
    end

    desc "Build the Torch app for the iOS Simulator"
    task :build do
      sh "xcodebuild -project #{TORCH_PROJ.shellescape} " \
         "-scheme Torch -destination 'generic/platform=iOS Simulator' " \
         "-derivedDataPath #{TORCH_DERIVED.shellescape} " \
         "ARCHS=arm64 ONLY_ACTIVE_ARCH=NO EXCLUDED_ARCHS=x86_64 build"
    end

    desc "Boot a simulator, install, and launch the Torch app"
    task :run do
      app = Dir.glob(File.join(TORCH_DERIVED, "Build", "Products",
                               "*-iphonesimulator", "Torch.app")).first
      raise "app not built; run `rake ios:torch:build`" unless app
      udid = `xcrun simctl list devices available`.lines
             .grep(/iPhone/).first&.match(/\(([0-9A-F-]{36})\)/)&.captures&.first
      raise "no available iPhone simulator" unless udid
      sh "xcrun simctl boot #{udid} 2>/dev/null; true"
      sh "open -a Simulator"
      sh "xcrun simctl install #{udid} #{app.shellescape}"
      sh "xcrun simctl launch #{udid} #{TORCH_BUNDLE}"
    end

    desc "Full Torch Simulator pipeline: lib -> gen -> build -> run"
    task all: [:lib, :gen, :build, :run]

    namespace :device do
      desc "Cross-build libmruby.a (iphoneos arm64) WITH picoruby-iphone-torch and stage under examples/iphone-torch/Vendor"
      task lib: :setup do
        stage_libmruby("r2p2-picoruby-ios-torch-device.rb", "ios-torch-device", TORCH_VENDOR)
      end

      desc "Build the Torch app, signed, for the connected iOS device"
      task :build do
        dest = `xcodebuild -project #{TORCH_PROJ.shellescape} -scheme Torch -showdestinations 2>/dev/null`.lines
               .grep(/platform:iOS,/).reject { |l| l =~ /Simulator|placeholder/ }
               .first&.match(/id:(\S+)/)&.captures&.first
        raise "no connected iOS device destination (xcodebuild -showdestinations)" unless dest
        sh "xcodebuild -project #{TORCH_PROJ.shellescape} -scheme Torch " \
           "-destination 'id=#{dest}' " \
           "-derivedDataPath #{TORCH_DEVICE_DERIVED.shellescape} " \
           "ARCHS=arm64 -allowProvisioningUpdates build"
      end

      desc "Install and launch the Torch app on the connected iOS device"
      task :run do
        app = Dir.glob(File.join(TORCH_DEVICE_DERIVED, "Build", "Products",
                                 "*-iphoneos", "Torch.app")).first
        raise "app not built; run `rake ios:torch:device:build`" unless app
        dev = `xcrun devicectl list devices`.lines
              .grep(/iPhone|iPad/).first&.match(/([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})/)&.captures&.first
        raise "no connected iOS device (xcrun devicectl list devices)" unless dev
        sh "xcrun devicectl device install app --device #{dev} #{app.shellescape}"
        sh "xcrun devicectl device process launch --console --device #{dev} #{TORCH_BUNDLE}"
      end

      desc "Full Torch device pipeline: lib -> gen -> build -> run (needs a connected, signed device)"
      task all: [:lib, "ios:torch:gen", :build, :run]
    end
  end
```

- [ ] **Step 4: Cross-build the library (this is the gem-compiles-and-archives gate)**

Run: `rake ios:torch:lib`
Expected: ends with `Staged ios-torch-sim libmruby.a + headers under .../examples/iphone-torch/Vendor`. The compile of `src/torch.c` and `ports/darwin/torch.c` must succeed. `ptorch_*` stay undefined in the `.a` (resolved at app link) — that is expected and does NOT fail the archive step.

- [ ] **Step 5: Confirm the torch port object made it into the archive**

Run: `ar t examples/iphone-torch/Vendor/lib/libmruby.a | grep -i torch`
Expected: object names containing `torch` (e.g. `torch.o` / `src` / `ports/darwin`). If empty, `conf.ports :darwin` did not pick up the port — recheck the gem path and that `ports/darwin/torch.c` exists.

- [ ] **Step 6: Commit**

```bash
git add build_config/r2p2-picoruby-ios-torch-sim.rb build_config/r2p2-picoruby-ios-torch-device.rb Rakefile
git commit -m "build(iphone-torch): example-scoped sim/device build configs + rake torch namespace"
```

---

## Task 4: app.rb + Swift app sources

**Files:**
- Create: `examples/iphone-torch/app.rb`
- Create: `examples/iphone-torch/Sources/App.swift`
- Create: `examples/iphone-torch/Sources/ContentView.swift`
- Create: `examples/iphone-torch/Sources/VMExecutor.swift`
- Create: `examples/iphone-torch/Sources/Torch-Bridging-Header.h`

- [ ] **Step 1: Write `app.rb`**

```ruby
# iPhone Torch — the whole behaviour is Ruby. The `Torch` class comes from the
# linked picoruby-iphone-torch gem; its on/off/available? drive AVCaptureDevice
# through the gem's Darwin port. This app owns the dispatch the Swift buttons call.
#
# vm_call(vm, "on"/"off", "") invokes $app.on / $app.off and returns whatever this
# prints (captured stdout), which the UI appends to its log. No timer: torch is a
# fire-and-forget on/off, so there is no poll loop.
class TorchApp
  def initialize
    @torch = Torch.new
    @log = []
    if @torch.available?
      log "ready: torch available"
    else
      log "ready: no torch on this device (Simulator?) — on/off will be no-ops"
    end
  end

  def on(arg = nil)
    if @torch.on
      log "torch ON"
    else
      log "torch unavailable (no actuation)"
    end
    flush_log
  end

  def off(arg = nil)
    if @torch.off
      log "torch OFF"
    else
      log "torch unavailable (no actuation)"
    end
    flush_log
  end

  private

  def log(msg)
    @log.push(msg)
  end

  def flush_log
    return nil if @log.empty?
    out = @log.join("\n")
    @log = []
    print out
    nil
  end
end

$app = TorchApp.new
```

- [ ] **Step 2: Write `Sources/App.swift`**

```swift
import SwiftUI

@main
struct TorchApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

- [ ] **Step 3: Write `Sources/VMExecutor.swift` (vperiph's executor minus the timer, plus an on-demand `call`)**

```swift
import Foundation

// Owns the persistent PicoRuby VM. mruby is single-threaded, so vm_open /
// vm_call / vm_close MUST all run on ONE thread. This serial DispatchQueue is
// that thread; the SwiftUI layer only posts onto it. app.rb defines $app =
// TorchApp.new at boot; each button posts a `call("on"/"off")` which runs
// vm_call on the VM thread and returns app.rb's printed log line.
final class VMExecutor {
    static let shared = VMExecutor()

    private let queue = DispatchQueue(label: "com.bash0c7.torch.vm")
    private var vm: UnsafeMutableRawPointer?
    private var onLog: ((String) -> Void)?

    private init() {}

    func start(bootSource: String, onLog: @escaping (String) -> Void) {
        self.onLog = onLog
        queue.async {
            guard let handle = bootSource.withCString({ vm_open($0) }) else {
                NSLog("[Torch] vm_open returned NULL (app.rb failed to load)")
                DispatchQueue.main.async { onLog("(VM failed to start — app.rb did not load)") }
                return
            }
            self.vm = handle
            NSLog("[Torch] VM opened")
            // app.rb's readiness line printed during boot is not captured by
            // vm_open; the UI shows its own "VM ready" text. Button presses log.
        }
    }

    // Invoke `method` ("on"/"off") on $app, returning app.rb's captured stdout.
    func call(_ method: String) {
        queue.async {
            guard let vm = self.vm else { return }
            let out = method.withCString { m in "".withCString { a in vm_call(vm, m, a) } }
            let text = out.map { String(cString: $0) } ?? ""
            if let out = out { free(out) }
            if !text.isEmpty {
                NSLog("[Torch] %@", text)
                DispatchQueue.main.async { self.onLog?(text) }
            }
        }
    }
}
```

- [ ] **Step 4: Write `Sources/ContentView.swift` (ON / OFF buttons + log)**

```swift
import SwiftUI

// All torch behaviour lives in app.rb (driving AVCaptureDevice via the
// picoruby-iphone-torch Darwin port). This view boots the VM and maps the two
// buttons to vm_call("on") / vm_call("off"). Swift holds no torch logic.
struct ContentView: View {
    @State private var log: String = "Starting VM…"

    var body: some View {
        VStack(spacing: 16) {
            Text("iPhone Torch").font(.headline)
            Text("Ruby (PicoRuby) drives AVCaptureDevice through the picoruby-iphone-torch Darwin port.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 24) {
                Button("ON")  { VMExecutor.shared.call("on") }
                    .buttonStyle(.borderedProminent)
                Button("OFF") { VMExecutor.shared.call("off") }
                    .buttonStyle(.bordered)
            }
            .font(.title2)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(log.isEmpty ? "—" : log)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("LOGEND")
                }
                .frame(maxHeight: .infinity)
                .border(.gray)
                .onChange(of: log) { _, _ in proxy.scrollTo("LOGEND", anchor: .bottom) }
            }
        }
        .padding()
        .onAppear { boot() }
    }

    private func boot() {
        guard let url = Bundle.main.url(forResource: "app", withExtension: "rb"),
              let src = try? String(contentsOf: url, encoding: .utf8) else {
            log = "(could not read bundled app.rb)"
            return
        }
        log = "VM ready. Tap ON / OFF."
        VMExecutor.shared.start(bootSource: src) { line in
            if self.log.count > 8000 { self.log = String(self.log.suffix(6000)) }
            self.log += (self.log.isEmpty ? "" : "\n") + line
        }
    }
}
```

- [ ] **Step 5: Write `Sources/Torch-Bridging-Header.h`**

```c
#import "picoruby_bridge.h"
```

- [ ] **Step 6: Commit**

```bash
git add examples/iphone-torch/app.rb examples/iphone-torch/Sources
git commit -m "feat(iphone-torch): app.rb dispatcher + SwiftUI ON/OFF buttons (no timer)"
```

---

## Task 5: project.yml + generate

**Files:**
- Create: `examples/iphone-torch/project.yml`

- [ ] **Step 1: Write `project.yml`** (modeled on `virtual-peripheral/project.yml`; swap names, point the Swift package at PicoTorchDarwin, drop the Bluetooth Info.plist keys, add the torch build dirs to the header search path)

```yaml
name: Torch
options:
  bundleIdPrefix: com.bash0c7.picoruby
  deploymentTarget:
    iOS: "17.0"
packages:
  # The Darwin (AVCaptureDevice) torch backend Swift package. Its ptorch_* C
  # symbols resolve the undefined references in the staged libmruby.a at app link.
  PicoTorchDarwin:
    path: picoruby-iphone-torch/ports/darwin/ext
targets:
  Torch:
    type: application
    platform: iOS
    sources:
      - path: Sources
      - path: app.rb
        buildPhase: resources
      - path: ../../bridge
        includes:
          - "picoruby_bridge.c"
          - "picoruby_bridge.h"
          - "task_hal_ios.c"
    dependencies:
      - package: PicoTorchDarwin
        embed: true
    settings:
      base:
        SWIFT_OBJC_BRIDGING_HEADER: Sources/Torch-Bridging-Header.h
        GCC_PREPROCESSOR_DEFINITIONS:
          - "$(inherited)"
          - "PICORB_ALLOC_ESTALLOC"
          - "PICORB_ALLOC_ALIGN=8"
          - "MRB_NO_BOXING"
          - "MRB_INT64"
          - "MRB_UTF8_STRING"
          - "PICORB_PLATFORM_DARWIN"
          - "MRB_TICK_UNIT=4"
          - "MRB_TIMESLICE_TICK_COUNT=3"
          - "MRB_USE_TASK_SCHEDULER=1"
          - "MRB_USE_VM_SWITCH_DISPATCH=1"
          - "MRB_CONSTRAINED_BASELINE_PROFILE=1"
          - "MRB_HEAP_PAGE_SIZE=128"
        HEADER_SEARCH_PATHS:
          - "$(SRCROOT)/../../vendor/picoruby/include"
          - "$(SRCROOT)/../../vendor/picoruby/mrbgems/mruby-compiler2/include"
          - "$(SRCROOT)/../../vendor/picoruby/mrbgems/mruby-compiler2/lib/prism/include"
          - "$(SRCROOT)/../../vendor/picoruby/mrbgems/picoruby-mruby/lib/mruby/include"
          - "$(SRCROOT)/../../vendor/picoruby/mrbgems/picoruby-mruby/include"
          - "$(SRCROOT)/../../build/ios-torch-sim/include"
          - "$(SRCROOT)/../../build/ios-torch-device/include"
          - "$(SRCROOT)/../../vendor/picoruby/mrbgems/picoruby-mruby/lib/mruby/mrbgems/mruby-task/include"
          - "$(SRCROOT)/../../bridge"
        LIBRARY_SEARCH_PATHS:
          - "$(SRCROOT)/Vendor/lib"
        OTHER_LDFLAGS:
          - "-lmruby"
        GENERATE_INFOPLIST_FILE: "YES"
        TARGETED_DEVICE_FAMILY: "1,2"
        PRODUCT_BUNDLE_IDENTIFIER: com.bash0c7.picoruby.Torch
        CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: SM5792D355
```

Note: no `INFOPLIST_KEY_NSCamera*` / `NSBluetooth*` keys — controlling the torch via `AVCaptureDevice.lockForConfiguration` needs no camera authorization (no capture session is started).

- [ ] **Step 2: Add `Vendor/` and generated project to `.gitignore` if not already covered**

Run: `grep -nE "Vendor|xcodeproj" .gitignore`
Expected: existing rules already ignore `Vendor/` and `*.xcodeproj` (vperiph relies on the same). If not present for the new path, add:
```
/examples/*/Vendor/
```
Only edit `.gitignore` if the existing patterns don't already match.

- [ ] **Step 3: Generate the Xcode project**

Run: `rake ios:torch:gen`
Expected: `Created project at .../examples/iphone-torch/Torch.xcodeproj`.

- [ ] **Step 4: Commit**

```bash
git add examples/iphone-torch/project.yml .gitignore
git commit -m "build(iphone-torch): xcodegen project.yml (links PicoTorchDarwin, no camera key)"
```

---

## Task 6: Build + run on Simulator (link + boot gate)

- [ ] **Step 1: Build the app for the Simulator (the app-link gate — ptorch_* must resolve)**

Run: `rake ios:torch:build`
Expected: `** BUILD SUCCEEDED **`. If linker reports undefined `_ptorch_set`/`_ptorch_available`, the Swift package dependency/embed is misconfigured in `project.yml`.

- [ ] **Step 2: Launch on the Simulator and confirm the VM boots**

Run: `rake ios:torch:run`
Expected: the Torch app launches in the Simulator showing ON / OFF buttons. The log shows `VM ready. Tap ON / OFF.`

- [ ] **Step 3: Tap ON, then OFF in the Simulator; confirm graceful no-op**

Manual (Simulator UI, or `xcrun simctl` is not needed): tap ON then OFF.
Expected: log appends `torch unavailable (no actuation)` for each (the Simulator has no torch). No crash. This proves the full Ruby → C → port → Swift path executes; only the hardware is absent.

- [ ] **Step 4: Commit (nothing to commit if all prior tasks committed; otherwise commit any fixes)**

```bash
git status   # if fixes were needed, commit them with a descriptive message
```

---

## Task 7: README

**Files:**
- Create: `examples/iphone-torch/README.md`

- [ ] **Step 1: Write `README.md`** documenting: what the example shows (Ruby drives AVCaptureDevice torch via a picoruby port), the gem layout (ABI / src / ports/darwin / ext Swift), how to build/run (`rake ios:torch:all` for sim, `rake ios:torch:device:all` for a connected device), and that the Simulator has no torch so actuation is device-only. Mirror the structure and depth of `examples/virtual-peripheral/README.md`.

- [ ] **Step 2: Commit**

```bash
git add examples/iphone-torch/README.md
git commit -m "docs(iphone-torch): example README"
```

---

## Task 8 (device, human-gated): physical actuation

- [ ] **Step 1: Cross-build + build + run on a connected, signed device**

Run: `rake ios:torch:device:all`
Expected: app installs and launches on the device.

- [ ] **Step 2: Human verification (physical, cannot be automated)**

Tap ON → the iPhone torch lights. Tap OFF → it turns off. Log shows `torch ON` / `torch OFF`. This step requires a physical device and human observation; leave it for the user.

---

## Self-Review notes

- **Spec coverage:** gem structure (Task 1), Swift backend (Task 2), build configs + ports selection (Task 3), app.rb + UI two buttons + no timer (Task 4), project.yml no camera key + ABI defines (Task 5), sim link/boot/no-op (Task 6), README (Task 7), device actuation human-gated (Task 8). Reduced-VM language probe is covered implicitly: app.rb uses only class/def/Array#push/join/print — all in the reduced surface; the sim boot in Task 6 Step 2 exercises it on the real VM.
- **Type consistency:** ABI `TORCH_set(bool)`/`TORCH_available(void)` ↔ Swift `ptorch_set(Int32)->Int32`/`ptorch_available()->Int32` ↔ Ruby `Torch#on/off/available?`. Gem init `mrb_picoruby_iphone_torch_gem_init`. Build names `ios-torch-sim`/`ios-torch-device` match `stage_libmruby` calls and `HEADER_SEARCH_PATHS`. Bundle id `com.bash0c7.picoruby.Torch`, scheme/target `Torch`, project `Torch.xcodeproj` consistent across Rakefile + project.yml.
- **Open risk:** the `@c` vs `@_cdecl` Swift attribute — Task 2 Step 4 verifies against the installed toolchain and the existing PicoBLEExports convention before proceeding.
