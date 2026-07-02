# watch-led-toggle — an LED blink, in Ruby, on the Apple Watch

The embedded "hello world" is the blinking LED. An Apple Watch has no LED, so
this example stands one in on screen: a 🔴 / 🔵 you toggle by tapping. The state
machine — which colour is on, and how a tap flips it — lives in `app.rb` and runs
in a PicoRuby VM on the watch itself.

This is a **watchOS standalone app** (`WKWatchOnly`), built for a physical
Apple Watch (`arm64_32`) and the watchOS Simulator.

## Where PicoRuby runs

**The LED state machine is `app.rb`**, a plain Ruby object:

```ruby
class LEDApp
  def initialize
    @state = "red"
  end

  def tick(_)
    print @state
  end

  def toggle(_)
    @state = @state == "red" ? "blue" : "red"
    print @state
  end
end

$app = LEDApp.new
puts "booted"
```

Swift owns no colour logic. It hosts the VM and relays the result:

```
ContentView (🔴/🔵 Text, .onTapGesture)
        │
        ├─ .onAppear ─▶ VMExecutor.start ─▶ vm_open(app.rb)      one persistent VM
        │                                     LEDApp.new, $app
        │
        ├─ 0.1s timer ─▶ vm_call($app, "tick")   ─▶ "red"/"blue" ─▶ updates the Text
        └─ tap        ─▶ vm_call($app, "toggle") ─▶ flips @state, returns new colour
```

`@state == "red" ? "blue" : "red"` is evaluated **by the mruby VM on the watch** —
the colour Swift renders is whatever Ruby returns. `vm_call` invokes a method on
the Ruby global `$app` and returns the method's captured `print` output as a
string; `VMExecutor` maps that to the SwiftUI `@State` that picks 🔴 or 🔵.

## What it took — the engineering notes

The interesting work is below SwiftUI: getting a PicoRuby VM to link and run on a
physical Apple Watch, whose CPU ABI is unlike anything else Apple ships.

### 1. `arm64_32` — a 32-bit-pointer ABI on a 64-bit core

A physical Apple Watch (Series 4+) runs **`arm64_32` (ILP32)**: ARM64 registers,
but **32-bit pointers**. The Simulator on an Apple-silicon Mac is ordinary 64-bit
`arm64`, so "works in the Simulator" proves nothing about the watch.

`mrb_value`'s in-memory representation is exactly what an ILP32 target breaks:

- **word boxing / NaN boxing pack a tag and a pointer into one machine word** and
  assume a 64-bit pointer. On `arm64_32` they are invalid.
- So this build uses **`MRB_NO_BOXING` + `MRB_INT64`**: `mrb_value` is a struct
  (a union + a type tag), the 32-bit pointer lives in the union unpacked, and
  integers stay 64-bit. This is the only boxing choice that is correct on the
  watch.

### 2. Producing an `arm64_32` `libmruby.a`

picoruby's mruby build (`MRuby::CrossBuild`) compiles host-arch / `arm64`
objects; it does not target `arm64_32` directly. `rake ios:watch:device:lib`
handles both steps as one task: it cross-builds with
`build_config/r2p2-picoruby-watchos-device.rb`, then runs
`build_config/recompile_arm64_32.rb` and re-stages the result under
`Vendor/lib`, so the archive that ships to Xcode is always `arm64_32`-only.

`recompile_arm64_32.rb` walks the build dir, finds each object's source via its
`.d` depfile, recompiles it with `-arch arm64_32`, and re-archives an
`arm64_32`-only `libmruby.a`. On a build_config whose `cc.flags` already target
`-arch arm64_32` (the current one), this step is a safety net rather than a
structural necessity — it recompiles 0 objects and just re-verifies the archive
is `arm64_32`-only.

### 3. One source of truth for the ABI defines

The `mrb_value`-determining defines (`MRB_INT64`, `MRB_NO_BOXING`,
`MRB_CONSTRAINED_BASELINE_PROFILE`, …) are read by **three** compilers and must
agree byte-for-byte, or the final archive mixes objects with different
`mrb_value` / `mrb_state` layouts and corrupts memory at runtime:

| compiler | defines come from |
|---|---|
| `rake ios:watch:device:lib` (mruby objects) | `build_config/r2p2-picoruby-watchos-device.rb` |
| `recompile_arm64_32.rb` (arm64_32 recompile) | **parses the same build_config** |
| Xcode (`picoruby_bridge.c`, app) | `project.yml` `GCC_PREPROCESSOR_DEFINITIONS` |

`recompile_arm64_32.rb` parses `conf.cc.defines` straight out of the build_config
rather than carrying its own list, so the recompile can never drift from the
mruby objects it is re-archiving with.

### 4. A big VM thread stack

watchOS gives `DispatchQueue` worker threads a very small stack — too small for
mruby VM + prism compiler init. `VMExecutor` runs the VM on a dedicated `Thread`
with an explicit **4 MB stack** (`Thread.stackSize`) and pins every VM call to
that thread's serial queue, so the whole VM lifetime stays single-threaded.

## Files

| File | Role |
|---|---|
| `app.rb` | the LED state machine (`LEDApp#tick` / `#toggle`), bundled as a resource |
| `Sources/VMExecutor.swift` | dedicated 4 MB-stack thread that owns the VM, the 0.1s tick timer, and `toggle()` |
| `Sources/ContentView.swift` | the 🔴/🔵 `Text`, `.onTapGesture` → toggle, `.onAppear` → boot |
| `Sources/App.swift` | the `@main` watchOS app entry |
| `Sources/WatchLEDToggle-Bridging-Header.h` | exposes the C VM bridge to Swift |
| `project.yml` | xcodegen project: `WKWatchOnly`, links `-lmruby`, mirrors the ABI defines |

The VM, the C bridge (`../../bridge`), and the build configs (`../../build_config`)
live one level up; this directory is the app plus `app.rb`.

## Run it

### Simulator

```sh
rake ios:watch:all     # lib -> gen -> build -> boot a watch sim -> install -> launch
```

### Physical Apple Watch (`arm64_32`)

```sh
rake ios:watch:device:all   # lib (+ arm64_32 recompile) -> gen -> build -> install -> launch
```

Or step by step: `rake ios:watch:device:lib && rake ios:watch:gen &&
rake ios:watch:device:build && rake ios:watch:device:run`. `:run` finds the
paired watch via `xcrun devicectl list devices` automatically.

On launch the console shows `booted` then `VM opened` (the boot Ruby ran and the
VM is live); tapping the screen flips 🔴 ⇄ 🔵. Set `DEVELOPMENT_TEAM` in
`project.yml` to your own team; the first launch of the bundle id needs a
one-time on-device trust, and if the watch is locked, `:run` fails with a
`FBSOpenApplicationErrorDomain error 7 Locked` — unlock it and re-run.

Confirmed working on a physical Apple Watch Series 8 (watchOS 26): `VM opened`
in console, and the toggle button visibly flips the LED colour.
