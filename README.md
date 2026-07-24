# R2P2-darwin

[![CI](https://github.com/bash0C7/R2P2-darwin/actions/workflows/ci.yml/badge.svg)](https://github.com/bash0C7/R2P2-darwin/actions/workflows/ci.yml)

日本語版: [README_jp.md](README_jp.md)

A self-contained harness for building and running PicoRuby on Apple platforms:
a macOS host, iOS (Simulator and signed physical device), and watchOS. It
cross-builds picoruby into a static library, links it into SwiftUI apps
through a thin C bridge, and ships examples that put the application's
behavior in Ruby. picoruby bakes the prism compiler into the VM, so the apps
compile and run Ruby source at runtime, on the device.

## Getting Started

The shortest path to PicoRuby running on an Apple platform — the repl example
on the iOS Simulator, no signing required:

1. Install the full Xcode.app (App Store; the Command Line Tools alone are not
   enough) and point the toolchain at it:

   ```sh
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -license accept
   ```

2. `brew install xcodegen`

3. Clone and verify the prerequisites:

   ```sh
   git clone https://github.com/bash0C7/R2P2-darwin.git
   cd R2P2-darwin
   rake check
   ```

4. `rake ios`

`rake ios` fetches picoruby into `vendor/picoruby` (first run only; ~1.2 GB
with submodules, and build output brings the repo to ~3 GB), cross-builds
`libmruby.a`, generates the Xcode project, builds the app, and launches it in
the Simulator. Type `puts "hello #{1 + 2}"` into the app and tap Run: it
prints `hello 3`, compiled and executed by PicoRuby inside the app.

Ruby: any ambient install (rbenv / asdf / system) >= 2.7 works;
`.ruby-version` pins 4.0.5 for version managers.

## What this is

`R2P2-darwin` connects picoruby to Apple's build systems (Xcode / xcodebuild /
Simulator / signing on iOS and watchOS; clang + Swift on the macOS host). It
is the analogue of [R2P2-ESP32](https://github.com/picoruby/R2P2-ESP32) on the
Apple axis: a self-contained harness, because iOS and watchOS are their own
substantial external build systems the way ESP-IDF is.

picoruby is a common PicoRuby core whose mrbgems carry per-architecture
implementations under `mrbgems/<gem>/ports/<arch>/` (rp2040 / posix / esp32 /
darwin ...) behind identical interfaces. R2P2-darwin holds the build configs
that select the Apple-appropriate ports, plus the C bridge and the example
apps. Apple-specific glue lives here; the picoruby tree stays pristine.

A single `vendor/picoruby` checkout feeds every platform. `rake setup` fetches
it (each lib task depends on setup, so it also happens on demand);
`rake refresh` re-fetches `PICORUBY_REF` into the existing checkout. Build
output goes to `./build` (`MRUBY_BUILD_DIR`), so the fetched source is never
mutated. Environment variables:

| Variable | Default | Controls |
|---|---|---|
| `PICORUBY_REPO` | `https://github.com/bash0C7/picoruby.git` | picoruby source repo |
| `PICORUBY_REF` | `port-darwin` | ref to fetch — master + darwin ports + net fix (see [Vendor fork](#vendor-fork)) |
| `IOS_MIN` | `17.0` | iOS deployment minimum (iOS build configs) |
| `WATCHOS_MIN` | `11.0` | watchOS deployment minimum (watchOS build configs) |
| `PICORUBY_BLE_GEMDIR` | vendor's `picoruby-ble` | alternate picoruby-ble checkout for the BLE examples |

## Examples

Each iOS / watchOS example is a SwiftUI app whose behavior lives in `app.rb`;
each has its own README with the details. `rake <ns>:all` runs the Simulator
pipeline (lib → gen → build → run) and `rake <ns>:device:all` builds, signs,
installs, and launches on a connected device — see
[On-device builds](#on-device-builds).

| Example | rake namespace | What it shows |
|---|---|---|
| [ios/repl](examples/ios/repl/README.md) | `ios:repl` (aliased as `ios`) | evaluate Ruby typed into the app, full-REPL VM |
| [ios/networking](examples/ios/networking/README.md) | `ios:net` | HTTP/TLS from Ruby — picoruby-net over mbedTLS, no URLSession |
| [ios/virtual-peripheral](examples/ios/virtual-peripheral/README.md) | `ios:vperiph` | a BLE peripheral written in Ruby (CoreBluetooth via the picoruby-ble darwin port) |
| [ios/iphone-torch](examples/ios/iphone-torch/README.md) | `ios:torch` | the iPhone "L-chika": flashlight driven from `app.rb` |
| [ios/stackchan](examples/ios/stackchan/README.md) | `ios:stackchan` | a BLE central driving a [Stack-chan](https://github.com/meganetaaan/stack-chan) robot over NUS |
| [ios/tilt-synth](examples/ios/tilt-synth/README.md) | `ios:tiltsynth` | Device Motion FM synth — the sound mapping lives in `app.rb` |
| [watchos/led-toggle](examples/watchos/led-toggle/README.md) | `watchos:led` | an LED blink in Ruby on the Apple Watch (arm64_32) |

For example: `rake ios:torch:all` (Simulator) or `rake ios:torch:device:all`
(connected iPhone). `rake ios:vperiph:write` builds a macOS BLE central helper
that drives the peripheral from the Mac (`WRITE_HEX` etc. pass through the
environment).

### Verifying behavior: observe / determinism

`rake ios:repl:observe` is the official behavior-verification target: it
launches the built app on a frozen Simulator `OBSERVE_N` times (env
`SIM_UDID` / `OBSERVE_N`, default 5) and classifies each run OK (the repl
example prints `hello 3`) or CRASH (a new crash report or crash signature).
If the runs disagree, it aborts as NON-DETERMINISTIC — that's how an
uncontrolled input gets caught. This is what turns "same build options ×
same built code → same behavior" into an enforced property rather than an
assumption. Raw logs land under `build/observe/`.

`rake determinism:ios:repl` is a companion build-content check: it
clean-builds `ios-repl`'s `libmruby.a` twice and compares object-content
hashes (ignoring `ar` header timestamp noise) to verify the build itself is
reproducible.

Operational notes:
- observe pins to one frozen Simulator (`SIM_UDID`, defaulted in the
  Rakefile) — don't recreate/erase/factory-reset it; its container state is
  a controlled variable across runs.
- After changing a build_config's defines, `rm -rf build/ios-repl-sim`
  before rebuilding — picoruby's per-object compile rule keys only on the
  `.c` mtime, not on build_config changes, so a stale `.o` is reused and the
  change silently fails to take effect.

Only `ios:repl` is wired up today; the same `define_ios_example` /
platform-namespace pattern extends to the other iOS examples and, later, to
watchOS/macOS.

### macOS host

macOS runs picoruby natively — host build modes, not example apps. Output
lands in `./build/host/bin`. `rake macos:check` verifies the host
prerequisites (the Command Line Tools are enough; Homebrew `openssl@3` is
needed only for host builds pulling the networking gembox).

```sh
rake macos:build                                # ./build/host/bin/{r2p2,picoruby}
rake macos:run                                  # r2p2 shell
rake macos:run APP=path/to.rb                   # run a Ruby file
rake macos:single APP=examples/macos/ls/ls.rb   # one self-contained binary embedding the script
```

`MRUBY_CONFIG` selects the build config (default: the Darwin host base
`build_config/r2p2-picoruby-darwin.rb`; `r2p2-picoruby-darwin-ble.rb` opts
into picoruby-ble / CoreBluetooth).

A binary built with `r2p2-picoruby-darwin-ble.rb` cannot be run by directly
executing `./build/host/bin/picoruby` at runtime: macOS's TCC framework hard-
aborts (`SIGABRT`) any CoreBluetooth call from a process not launched through
LaunchServices out of an app bundle declaring
`NSBluetoothAlwaysUsageDescription` — even a signed, previously-authorized
binary. Consumers that need BLE at runtime wrap the built binary in such a
bundle and launch it with `open -a` (see
[stackchan-picoruby's `pc/stackchan-pico`](https://github.com/bash0C7/stackchan-picoruby/tree/main/pc/stackchan-pico)
for a working example).

## On-device builds

Device tasks build for the connected iPhone or Apple Watch with automatic
signing. Before the first device build:

1. Find your Team ID in Xcode → Settings → Accounts (a free Apple ID works).
2. In the example's `project.yml`, replace `DEVELOPMENT_TEAM: YOUR_TEAM_ID`
   with your Team ID. If the bundle id collides inside your team, change
   `bundleIdPrefix` too.
3. The first launch of each bundle id needs a one-time on-device trust:
   Settings → General → VPN & Device Management → your Apple ID → Trust.

## How it fits together

```
examples/ios/<name>/Sources (SwiftUI)
        │  Swift ⇄ C bridging header
        ▼
bridge/picoruby_bridge.c   ──▶  libmruby.a (iOS arm64)
  repl_eval(src)                  prism compiler + mruby VM
  vm_open / vm_call / vm_close    cross-built from vendor/picoruby by
                                  build_config/r2p2-picoruby-ios-<name>-{sim,device}.rb
```

- `bridge/picoruby_bridge.c` — `repl_eval(src)` evaluates Ruby in a fresh VM
  and captures stdout/stderr; `vm_open`/`vm_call`/`vm_close` own a persistent
  VM and invoke a method on the Ruby global `$app` (every example except
  `repl`). One owner thread touches the VM.
- `bridge/task_hal_ios.c` — a polling task-scheduler HAL for iOS (no SIGALRM).
- Gems are linked statically; there is no runtime `require`. Every mrbgem in
  the build config is compiled into `libmruby.a` and registered when the VM
  opens, so `app.rb` uses classes like `BLE` directly. To make a class
  available to an example, add its gem to that example's build config.

Two gembox shapes coexist, per example. `repl` and `networking` use the
full-REPL gembox (`mruby-posix` + `core` + `stdlib` + `shell`,
`conf.ports :darwin, :posix`) — the full Ruby surface at the cost of a larger
link. The other examples use a reduced gem set without POSIX: core Ruby only —
no `puts` (the bridge shims it over `print`), no `defined?` / `String#ord` /
`String#%`. An example that needs more (e.g. `Array#pack`, `sprintf`) adds the
gem to its own example-scoped build config — see `examples/ios/stackchan`.
Probe new bundled Ruby against `rake smoke`'s host build before relying on it
on-device.

## Vendor fork

The default vendor source (`bash0C7/picoruby`, branch `port-darwin`) is
upstream master plus the darwin ports (ble / rng / mbedtls / io-console /
machine) and an allocator fix to picoruby-net's POSIX port that iOS networking
depends on (the receive buffer must come from the VM allocator, because the
iOS bridge runs the VM on an estalloc pool). Upstream `picoruby/picoruby`
master has neither, so pointing `PICORUBY_REF` at upstream breaks
`networking`, `virtual-peripheral`, and `stackchan`. Any fork/branch carrying
these works — the vendor is not pinned to one ref.

## Verified environment

| | Verified with |
|---|---|
| macOS | 26.5 |
| Xcode | 26.5 (17F42) |
| Ruby | 4.0.5 |

Device builds have been exercised against a physical iPhone (arm64) and Apple
Watch (arm64_32) with a free-Apple-ID personal team.

## Layout

```
R2P2-darwin/
  Rakefile                  check / setup / refresh / smoke / ios:<example>:* / watchos:led:* / clean / clobber
  rakelib/macos.rake        macos:check / macos:build / macos:run / macos:single
  build_config/             MRuby build configs: r2p2-picoruby-ios-<example>-{sim,device}.rb,
                            r2p2-picoruby-watchos-{sim,device}.rb + recompile_arm64_32.rb,
                            r2p2-picoruby-darwin*.rb (macOS host), r2p2-picoruby-host.rb (rake smoke)
  bridge/                   picoruby_bridge.{c,h}, task_hal_ios.c, smoke_test.c
  examples/
    ios/<name>/             SwiftUI app + app.rb (+ example-local gems where used)
    macos/ls/               demo script for rake macos:single
    watchos/led-toggle/     the watchOS example
  vendor/picoruby/          fetched by rake setup (gitignored)
  build/                    build output, MRUBY_BUILD_DIR (gitignored)
```

## License

[MIT](LICENSE)
