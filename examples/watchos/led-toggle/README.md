# led-toggle — an LED blink, in Ruby, on the Apple Watch

日本語版: [README_jp.md](README_jp.md)

The embedded hello world is a blinking LED. An Apple Watch has no LED, so this
example stands one in on screen: a red or blue circle you flip by tapping. Which
colour is on, and how a tap changes it, lives in `app.rb` and runs in a PicoRuby
VM on the watch itself.

It is a watchOS standalone app (`WKWatchOnly`), built for a physical Apple Watch
(`arm64_32`) and for the watchOS Simulator.

## How it works

The state machine is `app.rb`, a plain Ruby object:

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
ContentView (red/blue circle Text, .onTapGesture)
        │
        ├─ .onAppear ──> VMExecutor.start ──> vm_open(app.rb)   one persistent VM
        │                                       LEDApp.new, $app
        │
        ├─ 0.1s timer ──> vm_call($app, "tick")   ──> "red"/"blue" ──> updates the Text
        └─ tap        ──> vm_call($app, "toggle") ──> flips @state, returns the new colour
```

`@state == "red" ? "blue" : "red"` is evaluated by the mruby VM on the watch, so
the colour Swift renders is literally whatever Ruby returned. `vm_call` invokes a
method on the Ruby global `$app` and hands back that method's captured `print`
output as a string; `VMExecutor` maps it to the SwiftUI `@State` that selects the
circle.

## Engineering notes

Everything below SwiftUI here is about getting a PicoRuby VM to link and run on a
physical Apple Watch, whose CPU ABI is unlike anything else Apple ships.

### arm64_32: 32-bit pointers on a 64-bit core

A physical Apple Watch (Series 4 and later) runs `arm64_32` — ILP32: ARM64
registers, 32-bit pointers. The Simulator on an Apple-silicon Mac is ordinary
64-bit `arm64`, so a green Simulator run proves nothing about the watch.

`mrb_value`'s in-memory representation is exactly what ILP32 breaks. Word boxing
and NaN boxing both pack a tag and a pointer into a single machine word and
assume that word holds a 64-bit pointer; neither is valid on `arm64_32`. This
build uses `MRB_NO_BOXING` with `MRB_INT64`: `mrb_value` becomes a struct — a
union plus a type tag — the 32-bit pointer sits unpacked inside the union, and
integers stay 64-bit. It is the only boxing choice that is correct on the watch.

### Producing an arm64_32 archive

picoruby's mruby build does not target `arm64_32` directly; without explicit
arch flags it emits host-arch or `arm64` objects. `rake watchos:led:device:lib`
closes that gap: it cross-builds, then runs
`build_config/recompile_arm64_32.rb`, which re-archives an `arm64_32`-only
`libmruby.a` before it reaches Xcode. You do not have to run that script
yourself — the task does it.

### No fork, no exec

The watchOS SDK forbids `fork` and `exec`. `mruby-io` — which is where `puts`
comes from — implements `IO.popen` with exactly those, so the build swaps in a
replacement (`hal-io-darwin`) that is the same code without the spawning.
`IO.popen` is therefore absent on the watch; everything else about `mruby-io`
behaves as it does on iOS.

### A large VM thread stack

watchOS gives `DispatchQueue` worker threads a stack too small for mruby VM plus
prism compiler initialization. `VMExecutor` therefore runs the VM on a dedicated
`Thread` with an explicit 4 MB stack (`Thread.stackSize`) and pins every VM call
to that thread's serial queue, keeping the whole VM lifetime single-threaded.

## Files

The VM, the C bridge (`../../../bridge`), and the build configs
(`../../../build_config`) live at the repository root; this directory is the app
plus `app.rb`.

- `app.rb` — the state machine (`LEDApp#tick`, `#toggle`), bundled as a resource.
- `Sources/VMExecutor.swift` — the dedicated 4 MB-stack thread that owns the VM,
  the 0.1 s tick timer, and `toggle()`.
- `Sources/ContentView.swift` — the red/blue circle `Text`, `.onTapGesture` to
  toggle, `.onAppear` to boot.
- `Sources/App.swift` — the `@main` watchOS app entry point.
- `Sources/WatchLEDToggle-Bridging-Header.h` — exposes the C VM bridge to Swift.
- `project.yml` — the xcodegen project: `WKWatchOnly`, links `-lmruby`, mirrors
  the ABI defines.

## Build and run

### Simulator

```sh
rake watchos:led:all     # lib -> gen -> build -> boot a watch sim -> install -> launch
```

### Device

Before the first device build, replace `DEVELOPMENT_TEAM: YOUR_TEAM_ID` in
`project.yml` with your own Team ID — see
[Running on a device](../../../README.md#running-on-a-device).

```sh
rake watchos:led:device:all   # lib (+ arm64_32 pass) -> gen -> build -> install -> launch
```

Or step by step:

```sh
rake watchos:led:device:lib
rake watchos:led:gen
rake watchos:led:device:build
rake watchos:led:device:run     # finds the paired watch via xcrun devicectl
```

`rake watchos:led:device:check` links for a generic watchOS device with signing
disabled, so you can catch SDK-level breakage without a watch attached.

On launch the console shows `booted` and then `VM opened` — the boot Ruby ran
and the VM is live. Tapping the screen flips the circle between red and blue.

Device notes:

- The first launch of the bundle id needs a one-time on-device trust.
- If the watch is locked, `:run` fails with
  `FBSOpenApplicationErrorDomain error 7 Locked`. Unlock it and re-run.
