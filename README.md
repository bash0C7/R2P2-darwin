# R2P2-darwin

日本語版: [README_jp.md](README_jp.md)

A self-contained harness for building and running PicoRuby on Apple platforms:
a macOS host, iOS (Simulator and signed physical device), and watchOS. It
cross-builds picoruby into a static library, links it into SwiftUI apps through
a thin C bridge, and ships examples that put the application's behavior in
Ruby. On the macOS host it builds picoruby's own `r2p2` / `picoruby` runners
natively.

## What this is

`R2P2-darwin` connects picoruby to Apple's build systems (Xcode / xcodebuild /
Simulator / signing on iOS and watchOS; clang + Swift on the macOS host). It is
the analogue of R2P2-ESP32 on the Apple axis: a self-contained harness, because
iOS and watchOS are their own substantial external build systems the way
ESP-IDF is.

picoruby is a common PicoRuby core whose mrbgems carry per-architecture
implementations under `mrbgems/<gem>/ports/<arch>/` (rp2040 / posix / esp32 /
darwin ...) behind identical interfaces. R2P2-darwin holds the build configs
that select the Apple-appropriate ports, plus the C bridge and the example
apps. Apple-specific glue lives here; the picoruby tree stays pristine.

A single `vendor/picoruby` checkout feeds every platform. It is selectable by
env:

```
PICORUBY_REPO   default: https://github.com/bash0C7/picoruby.git
PICORUBY_REF    default: port-darwin  (master + darwin ports: ble/rng/mbedtls/io-console/machine + net fix)
IOS_MIN         default: 17.0   (iOS deployment minimum, read by the iOS build configs)
EXAMPLE         default: repl   (which examples/ios/<name> the base ios:* tasks build)
```

`rake setup` fetches the tree into `vendor/picoruby`; `rake refresh` re-fetches
`PICORUBY_REF` into an existing checkout. Build output goes to `./build`
(`MRUBY_BUILD_DIR`), so the fetched source is never mutated.

picoruby bakes the prism compiler into the VM, so the cross-built `libmruby.a`
compiles and runs Ruby source at runtime, on the device.

## Setup

iOS and watchOS builds need the full Xcode.app (the iOS/watchOS SDKs,
Simulators, and xcodebuild live there); the Command Line Tools alone are not
enough. The macOS host build needs only the Command Line Tools; Homebrew
`openssl@3` is required only for host builds that pull the networking gembox
(ssl/crypto) and optional otherwise.

```
# full Xcode.app (App Store) — for iOS / watchOS. Point the toolchain at it (needs sudo):
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept

brew install xcodegen         # generates each example's Xcode project (iOS / watchOS)
brew install openssl@3        # only for macOS host builds pulling the networking gembox (ssl/crypto)
# Ruby — any ambient install (rbenv / asdf / system) >= 2.7
```

```
rake check                    # verifies full Xcode / iOS SDK / xcodegen
rake macos:check              # verifies Xcode CLT / brew openssl@3 / Swift for host builds
```

## Examples

The iOS and watchOS entries below are example apps; the macOS section covers
host build modes rather than example apps. Each iOS / watchOS example has its
own README explaining where and how PicoRuby is used:

- [`examples/ios/repl`](examples/ios/repl/README.md)
- [`examples/ios/networking`](examples/ios/networking/README.md)
- [`examples/ios/virtual-peripheral`](examples/ios/virtual-peripheral/README.md)
- [`examples/ios/iphone-torch`](examples/ios/iphone-torch/README.md)
- [`examples/ios/stackchan`](examples/ios/stackchan/README.md)
- [`examples/ios/tilt-synth`](examples/ios/tilt-synth/README.md)
- [`examples/watchos/led-toggle`](examples/watchos/led-toggle/README.md)

### iOS

Each iOS example builds for the Simulator and for a connected, signed device.

#### repl — evaluate Ruby on the device

A SwiftUI app with a text field, a Run button, and an output view wired to the
bridge. It compiles and runs whatever you type and shows the captured output;
`puts "hello #{1 + 2}"` prints `hello 3`, `raise "boom"` surfaces the exception
without crashing the app.

```
rake ios                      # Simulator: lib -> gen -> build -> run (headless)
rake ios:device:all           # connected device: build, sign, install, launch
```

#### networking — HTTP/TLS from Ruby

A raw BSD socket plus an mbedTLS handshake, both driven by `Net::HTTPSClient`
from the upstream `picoruby-net` gem, seeded by the `picoruby-mbedtls` /
`picoruby-rng` Darwin entropy ports (`SecRandomCopyBytes`). No OpenSSL, no
`URLSession` — this is PicoRuby's own TLS running on-device. Like `repl`, it
needs the full-REPL gembox (`posix?=true`), not the reduced VM the other
examples use. See the [example README](examples/ios/networking/README.md) for
the gembox rationale and the fork fix this example depends on.

```
rake ios:net:all              # Simulator: lib -> gen -> build -> run
rake ios:net:device:all       # connected device: build, sign, install, launch
```

#### virtual-peripheral — a BLE peripheral written in Ruby

A PicoRuby-first virtual BLE peripheral, useful as a test stub for debugging a
BLE central. `app.rb` is a `BLE` subclass (`role :peripheral`); the GATT
profile and every per-event behavior (advertise / read / write / subscribe /
notify) live in it, running in a persistent VM. CoreBluetooth is driven
through picoruby-ble's Darwin port — there is no Swift CoreBluetooth code;
Swift only hosts the VM (a tick timer) and a read-only log. It advertises a
Heart Rate profile as `PBLE-TEST` and answers reads, writes, and subscriptions
out of `app.rb`. The picoruby-ble Darwin port ships in the `bash0C7/picoruby`
fork that is the default `vendor/picoruby` source — see the
[example README](examples/ios/virtual-peripheral/README.md#dependencies).

```
rake ios:vperiph:all          # Simulator (advertising needs a real radio)
rake ios:vperiph:device:all   # connected device: build, sign, install, launch
rake ios:vperiph:write        # macOS BLE central helper that drives the peripheral
```

`rake ios:vperiph:write` builds and runs
`examples/ios/virtual-peripheral/tools/ble_write.swift`, a CoreBluetooth
central that scans for `PBLE-TEST`, connects, reads, subscribes, and writes.
`WRITE_HEX`, `TARGET_NAME`, and `APP_SERVICES` pass through the environment
(e.g. `WRITE_HEX=02 rake ios:vperiph:write`).

#### iphone-torch — Ruby-driven flashlight (the iPhone "L チカ")

The flashlight as the LED-blink of iOS: two buttons turn the iPhone torch on
and off. The whole behaviour is Ruby — `app.rb` calls a `Torch` class, and the
`picoruby-iphone-torch` gem's Darwin port turns those calls into
`AVCaptureDevice` torch operations. The SwiftUI layer only boots the VM and
forwards button taps; there is no torch logic in Swift. See the
[example README](examples/ios/iphone-torch/README.md) for the gem structure.

```
rake ios:torch:all            # Simulator: lib -> gen -> build -> run
rake ios:torch:device:all     # connected device: build, sign, install, launch
```

#### stackchan — a Stack-chan BLE central written in Ruby

A PicoRuby-first BLE central that connects to a
[Stack-chan](https://github.com/meganetaaan/stack-chan) robot running the
`stackchan-picoruby` firmware and sends face / LED / head / torque commands
over Nordic UART Service (NUS). The entire BLE logic — scan, connect, GATT
discovery, NUS RX write — lives in `app.rb` using `picoruby-ble`'s central
API; Swift only hosts the VM and forwards button taps. The example-specific
build config adds the three stdlib gems that `picoruby-ble`'s mrblib depends
on (`mruby-string-ext`, `mruby-pack`, `mruby-sprintf`) without touching the
minimal base config. See
[examples/ios/stackchan/README.md](examples/ios/stackchan/README.md) for
wiring details, the codec test, and known device constraints.

```
rake ios:stackchan:device:lib   # cross-build BLE-enabled libmruby.a for iphoneos
rake ios:stackchan:gen          # xcodegen generate
rake ios:stackchan:device:build # sign and build for the connected iPhone
rake ios:stackchan:device:run   # install + launch with console output
rake ios:stackchan:device:all   # lib -> gen -> build -> run in one step
```

#### tilt-synth — a Device Motion FM synthesizer in Ruby

Tilt the iPhone and Ruby makes sound. `app.rb` reads the Device Motion
attitude (pitch / roll) through the `picoruby-iphone-motion` gem's Darwin port
(`CMDeviceMotion`), quantizes pitch to a 2-octave C major pentatonic scale,
maps roll to FM depth, and drives an `AVAudioEngine` sine+FM oscillator
through the `picoruby-iphone-synth` gem's Darwin port. The scale, the ranges,
and the tick loop are all `app.rb`; neither gem's Swift backend contains
music-mapping logic. Both gems are local mrbgems (not in `vendor/picoruby`)
with the same structure as `picoruby-iphone-torch`. There is no button — the
tick timer runs from the moment the VM boots, the same always-on model as
`virtual-peripheral`. The Simulator has no Device Motion, so
`Motion#available?` is `false` there and the app stays silent; the Simulator
target verifies that the build links and the VM runs.
`ruby examples/ios/tilt-synth/test_mapping.rb` checks the quantize/clamp math
without Xcode. See the [example README](examples/ios/tilt-synth/README.md).

```
rake ios:tiltsynth:all          # Simulator: lib -> gen -> build -> run
rake ios:tiltsynth:device:all   # connected device: build, sign, install, launch (actual tilt + sound)
```

### macOS

macOS runs picoruby natively on the host; the subsections below are host build
modes, not example apps. Output lands in `./build/host/bin`. The build config
is selectable with `MRUBY_CONFIG` (default:
`build_config/r2p2-picoruby-darwin.rb`, the Darwin host base, which sets
`PICORB_PLATFORM_DARWIN` so the tree compiles as a Darwin host build rather
than a generic POSIX one).

#### Standard build

```
rake macos:build                    # ./build/host/bin/{r2p2,picoruby}
rake macos:run                      # r2p2 shell
rake macos:run APP=path/to.rb       # run a Ruby file on the picoruby runner
```

#### BLE variant (CoreBluetooth)

picoruby-ble's Darwin port uses CoreBluetooth, which only exists on Darwin.
Select the BLE build config (Darwin host base + `picoruby-ble` +
`picoruby-picotest` opt-in):

```
MRUBY_CONFIG=$(pwd)/build_config/r2p2-picoruby-darwin-ble.rb rake macos:build
```

Tests and design docs for the port live with the port itself under
`mrbgems/picoruby-ble/ports/darwin/` in the picoruby tree.

#### Single binary

`rake macos:single` builds one executable that embeds a Ruby script (`APP=`
required; `NAME=` optional, default: the script's basename) as the program it
runs; the script lives inside the binary,
so the file is standalone and portable. `examples/macos/ls/ls.rb` is a
realistic demo — an `ls`-like listing of the current directory.

```
rake macos:single APP=examples/macos/ls/ls.rb   # ./build/host/bin/ls
./build/host/bin/ls                             # one self-contained binary
```

### watchOS

The watchOS example builds for the watchOS Simulator and for a physical Apple
Watch (`arm64_32`).

#### led-toggle — an LED blink, in Ruby, on the Apple Watch

A watchOS standalone app: the embedded "hello world" LED, stood in by a red /
blue circle you toggle by tapping. The state machine lives in `app.rb`
(`LEDApp#tick` / `#toggle`) and runs in a persistent VM on the watch; Swift
hosts the VM and renders whatever colour Ruby returns. The notable work is the
CPU ABI: a physical Apple Watch is `arm64_32` (ILP32 — 64-bit registers,
32-bit pointers), so the VM is built `MRB_NO_BOXING` + `MRB_INT64` (word/NaN
boxing are invalid on ILP32), and an extra step recompiles the mruby objects
to `arm64_32`. See the
[example README](examples/watchos/led-toggle/README.md) for the full notes.

```
rake watchos:led:all          # watchOS Simulator: lib -> gen -> build -> run
rake watchos:led:device:all   # connected Apple Watch: build, sign, install, launch
```

### On-device builds

Device tasks build for the connected iPhone or Apple Watch with automatic
signing. Set `DEVELOPMENT_TEAM` in the example's `project.yml` to your own
team (a free Apple ID works); the first launch of each bundle id needs a
one-time on-device trust (Settings → General → VPN & Device Management → your
Apple ID → Trust).

## How it fits together

```
examples/ios/<name>/Sources (SwiftUI)
        │  Swift ⇄ C bridging header
        ▼
bridge/picoruby_bridge.c   ──▶  libmruby.a (iOS arm64)
  repl_eval(src)                  prism compiler + mruby VM
  vm_open / vm_call / vm_close    cross-built from vendor/picoruby by
                                  build_config/r2p2-picoruby-ios-repl-{sim,device}.rb
```

- `bridge/picoruby_bridge.c` — `repl_eval(src)` evaluates Ruby in a fresh VM
  and captures stdout/stderr; `vm_open`/`vm_call`/`vm_close` own a persistent
  VM and invoke a method on the Ruby global `$app` (every example except
  `repl`). One owner thread touches the VM.
- `bridge/task_hal_ios.c` — a polling task-scheduler HAL for iOS (no SIGALRM).
- `build_config/r2p2-picoruby-ios-repl-{sim,device}.rb` — `MRuby::CrossBuild`
  for the `iphonesimulator` / `iphoneos` SDKs via `xcrun`; the full-REPL VM.
- `build_config/r2p2-picoruby-host.rb` — the same gem set built for the host,
  so `rake smoke` can exercise the bridge quickly.
- `build_config/r2p2-picoruby-darwin.rb` — the Darwin host base for the
  `macos:` tasks, built natively (not a cross build).
- An example that needs extra gems (e.g. BLE) carries its own example-specific
  build config, so it never drags dependencies into the other examples' link.

Gems are linked statically; there is no runtime `require`. Every mrbgem
selected by the build config is compiled into `libmruby.a`, and its classes
are registered when the VM opens, so the example Ruby references them
directly — `virtual-peripheral`'s `app.rb` uses `BLE` with no `require`. The
reduced VM has no POSIX/VFS, so file-based `require` is not available in the
first place. To make a class available to an example, add its gem to that
example's build config, not a `require` in Ruby.

## Constraints worth knowing

Two gembox shapes coexist for the iOS/watchOS examples, per example.

`virtual-peripheral` / `iphone-torch` / `stackchan` / `tilt-synth` /
`led-toggle` use a reduced gem set — no `core`/`stdlib` gemboxes and no POSIX,
so the iOS-incompatible IO / VFS / machine-posix gems are absent. The Ruby
surface is therefore smaller than full mruby/CRuby:

- integer/float math, `String`, string interpolation, `print` / `p`, `raise`,
  `Hash`/`Array` literals + `each`, `while`, ternary, default args, and
  `begin`/`rescue` are available.
- `puts` is not in the reduced VM (it comes from an IO gem); the bridge
  installs a small `puts` shim defined in terms of core `print`.
- `defined?`, `String#ord`, `Integer#chr`, and `String#%` are absent in the
  base VM. Probe new bundled Ruby against the host build (`rake smoke`'s
  `libmruby.a`) before relying on it on-device.
- Examples that need `Array#pack`, `String#<<`, or `sprintf` add `mruby-pack`,
  `mruby-string-ext`, `mruby-sprintf` to their own example-scoped build
  config — see `examples/ios/stackchan`.

`repl` / `networking` use the full-REPL gembox (`mruby-posix` + `core` +
`stdlib` + `shell`, `build.posix?` true, `conf.ports :darwin, :posix`): iOS is
treated as a POSIX target, with `ports/darwin` preferred and `ports/posix` as
fallback per gem. This gets the full `core`/`stdlib` Ruby surface —
`Array#map`, `RNG`/`Machine`, exceptions surfaced with a backtrace via
`mrb_print_error` without crashing the host app — at the cost of a larger
link, which is why the other examples stay on the reduced gembox instead.
`Machine.unique_id` returns `nil` on iOS by design (`ports/darwin/machine.c`:
no C-only stable unique id on iOS, so it reports unavailable rather than
fabricating one) — not a bug.

## Vendor fork: darwin ports and the picoruby-net POSIX fix

The default `vendor/picoruby` source (`bash0C7/picoruby`, branch `port-darwin`)
carries the darwin ports (ble / rng / mbedtls / io-console / machine) and a
fix to picoruby-net's POSIX port:
`mrbgems/picoruby-net/ports/posix/{tcp,tls,udp}_client.c` allocates the
receive buffer (`res->recv_data`) with the VM allocator (`picorb_alloc` /
`picorb_realloc` / `picorb_free`, which resolve to `mrb_malloc` /
`mrb_realloc` / `mrb_free`), so it matches the `mrb_free` that
`src/mruby/net.c` frees it with — the same discipline the LwIP path
(`src/tcp.c`) keeps. As a fix to the shared POSIX port it applies to every
POSIX build of picoruby-net, the macOS host build included. Under mruby's
default allocator (`mrb_open`) `mrb_free` is system `free` and the distinction
is inert; the iOS bridge opens the VM with `mrb_open_with_custom_alloc` over
an 8 MB estalloc pool (`bridge/picoruby_bridge.c`), where a system-heap
pointer must never reach the pool's free — networking on iOS depends on this
fix. Upstream `picoruby/picoruby` master has neither the darwin ports nor the
fix, so pointing `PICORUBY_REF` at upstream breaks the examples that depend on
fork-only code: `networking` (the allocator fix and the darwin mbedtls/rng
entropy ports) and `virtual-peripheral` / `stackchan` (the picoruby-ble
darwin port).

## Layout

```
R2P2-darwin/
  Rakefile                          check / setup / refresh / smoke / host:lib / ios:* / watchos:led:* / clean / clobber
  rakelib/
    macos.rake                      macos:check / macos:build / macos:run / macos:single
  build_config/
    r2p2-picoruby-ios-repl-sim.rb    full REPL (posix?=true + darwin port-chain), iphonesimulator (CrossBuild)
    r2p2-picoruby-ios-repl-device.rb full REPL (posix?=true + darwin port-chain), iphoneos (CrossBuild)
    r2p2-picoruby-ios-net-sim.rb     full-REPL gembox + picoruby-net, iphonesimulator (CrossBuild)
    r2p2-picoruby-ios-net-device.rb  full-REPL gembox + picoruby-net, iphoneos (CrossBuild)
    r2p2-picoruby-ios-mbedtls-sim.rb base reduced VM + picoruby-mbedtls only, symbol-level checks
    r2p2-picoruby-ios-rng-sim.rb     base reduced VM + picoruby-rng only, symbol-level checks
    r2p2-picoruby-ios-io-console-sim.rb base reduced VM + picoruby-io-console only, symbol-level checks
    r2p2-picoruby-ios-vperiph-{sim,device}.rb   base reduced VM + picoruby-ble, darwin port
    r2p2-picoruby-ios-torch-{sim,device}.rb     base reduced VM + picoruby-iphone-torch, darwin port
    r2p2-picoruby-ios-stackchan-{sim,device}.rb base reduced VM + picoruby-ble + pack/string-ext/sprintf
    r2p2-picoruby-ios-tiltsynth-{sim,device}.rb base reduced VM + the local motion/synth gems, darwin ports
    r2p2-picoruby-watchos-sim.rb    base reduced VM, watchsimulator (CrossBuild)
    r2p2-picoruby-watchos-device.rb base reduced VM, watchos / arm64_32 (CrossBuild)
    recompile_arm64_32.rb           recompiles the device objects to arm64_32, re-archives
    r2p2-picoruby-host.rb           same gem set, host build for rake smoke
    r2p2-picoruby-darwin.rb         Darwin host base (macos:build default)
    r2p2-picoruby-darwin-ble.rb     Darwin host base + picoruby-ble opt-in
    r2p2-picoruby-darwin-single.rb  Darwin host base minus REPL/shell bins (macos:single)
    r2p2-stackchan-pc.rb            Darwin host build config for a Stack-chan PC central
  bridge/
    picoruby_bridge.{c,h}           repl_eval + persistent vm_open/vm_call/vm_close
    task_hal_ios.c                  polling task-scheduler HAL (no SIGALRM)
    smoke_test.c                    host-side bridge exercise
  docs/                             design plans and handoff notes
  examples/
    ios/
      repl/                         evaluate Ruby on the device
      networking/                   HTTP/TLS from Ruby (picoruby-net over mbedTLS)
      virtual-peripheral/           a BLE peripheral whose behavior lives in app.rb
        tools/ble_write.swift       macOS BLE central helper
      iphone-torch/                 Ruby-driven iPhone flashlight (picoruby-iphone-torch gem)
      stackchan/                    Stack-chan BLE central: face/LED/head/torque over NUS
      tilt-synth/                   Device Motion FM synth; mapping lives in app.rb
        picoruby-iphone-motion/     local gem: CMDeviceMotion attitude -> Motion
        picoruby-iphone-synth/      local gem: AVAudioEngine sine+FM -> Synth
    macos/
      ls/ls.rb                      current-dir listing, demo for rake macos:single
    watchos/
      led-toggle/                   a red/blue LED blink in Ruby, watchOS (arm64_32)
  vendor/picoruby/                  fetched by rake setup (gitignored)
  build/                            build output, MRUBY_BUILD_DIR (gitignored)
  tmp/single/                       throwaway bin gem generated per macos:single (gitignored)
```
