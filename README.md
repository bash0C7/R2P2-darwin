# R2P2-darwin

[![CI](https://github.com/bash0C7/R2P2-darwin/actions/workflows/ci.yml/badge.svg)](https://github.com/bash0C7/R2P2-darwin/actions/workflows/ci.yml)

日本語版: [README_jp.md](README_jp.md)

Build and run [PicoRuby](https://github.com/picoruby/picoruby) on Apple
platforms: the macOS host, iOS (Simulator and signed physical device), and
watchOS. This is the Apple member of the [R2P2 harness
family](#the-r2p2-family), alongside R2P2-ESP32 on the ESP-IDF side.

The repository cross-builds picoruby into a static library, links it
into SwiftUI apps through a thin C bridge, and ships example apps whose entire
behaviour lives in a Ruby file. PicoRuby bakes the prism compiler into the VM,
so those apps compile and run Ruby source at runtime, on the device.

## Quick start

The shortest path to PicoRuby running on an Apple platform: the `repl` example
on the iOS Simulator. No Apple Developer account and no signing needed.

1. Install the full Xcode.app (App Store — the Command Line Tools alone are not
   enough) and point the toolchain at it:

   ```sh
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -license accept
   ```

2. Install the project generator:

   ```sh
   brew install xcodegen
   ```

3. Clone and verify the prerequisites:

   ```sh
   git clone https://github.com/bash0C7/R2P2-darwin.git
   cd R2P2-darwin
   rake check
   ```

4. Build and launch:

   ```sh
   rake ios
   ```

`rake ios` fetches picoruby into `vendor/picoruby`, cross-builds `libmruby.a`
for the Simulator SDK, generates the Xcode project, builds the app, and
launches it. Type `puts "hello #{1 + 2}"` into the app and tap Run: it prints
`hello 3`, compiled and executed by PicoRuby inside the app.

The first run clones picoruby with submodules (~1.2 GB; build output brings the
working tree to roughly 3 GB). Any ambient Ruby >= 2.7 (rbenv / asdf / system)
drives the Rakefile; `.ruby-version` pins 4.0.5 for version managers.

## What this repository is

### The R2P2 family

R2P2 — Ruby Rapid Portable Platform — is PicoRuby's shell: an interactive Ruby
environment that runs on the target itself. It lives in picoruby as the
`picoruby-r2p2` picogem. Carrying it, and the VM underneath it, onto one
platform family's build system is the job of a separate *harness* repository:

| Harness | Platform family | How it obtains picoruby |
|---|---|---|
| `rake r2p2:*` inside [picoruby/picoruby](https://github.com/picoruby/picoruby) | Raspberry Pi Pico (RP2040 / RP2350) | it *is* the picoruby tree |
| [R2P2-ESP32](https://github.com/picoruby/R2P2-ESP32) | ESP32 family, through ESP-IDF | git submodule at `components/picoruby-esp32/picoruby`, pinned to an upstream commit |
| **R2P2-darwin** (this repository) | macOS host, iOS, watchOS, through Xcode | `rake setup` clones `PICORUBY_REF` into a gitignored `vendor/picoruby` |

The dependency mechanism differs on purpose. R2P2-ESP32 can pin upstream as a
submodule because every port it needs (`ports/esp32/`) is already upstream.
R2P2-darwin cannot: the darwin ports are developed alongside this harness, so
the checkout is a *fetch of a configurable ref* rather than a pinned submodule,
and it is gitignored rather than committed. That makes `PICORUBY_REPO` and
`PICORUBY_REF` first-class knobs here in a way they are not on the ESP32 side,
and it is why the default ref is a fork — see [Vendor source](#vendor-source).

What comes out differs too. A Pico or ESP32 build produces one firmware image,
and R2P2 is essentially the whole of it. Apple platforms have no such slot: an
app is a signed bundle assembled by Xcode. So this repository's primary product
is `libmruby.a` — the VM as a static library to link into a SwiftUI app through
a C bridge — and it ships example apps rather than a single firmware. The R2P2
shell itself does appear on the macOS host, where picoruby runs natively:
`rake macos:build` builds the `picoruby-bin-r2p2` executable and `rake macos:run`
drops you into that shell.

### Ports, and where the Apple glue lives

Each picoruby mrbgem keeps its architecture-specific code under
`mrbgems/<gem>/ports/<arch>/` — `rp2040`, `posix`, `esp32`, `darwin` — behind an
interface (`include/*.h`) that is identical across every port. A harness selects
ports; it does not fork the core.

R2P2-darwin therefore holds the MRuby build configs that select the
Apple-appropriate ports, the C bridge between Swift and the VM, and the example
apps. Apple-specific glue belongs here; the fetched picoruby tree stays pristine
and is never committed to.

### Darwin is a POSIX platform

iPhone, Apple Watch, and Mac all run Darwin (XNU plus BSD libc), so every build
config in this repository defines **both** `PICORB_PLATFORM_POSIX` and
`PICORB_PLATFORM_DARWIN`, and sets `conf.ports :darwin, :posix`.

- `PICORB_PLATFORM_POSIX` tells picoruby it has libc, threads, file
  descriptors, and signals. Dropping it to shrink the VM would force the MCU
  port contract (hardware clock, GPIO sleep, littlefs, watchdog) onto a system
  that has none of those problems.
- `PICORB_PLATFORM_DARWIN` marks the Apple-specific differences: CoreBluetooth
  instead of BTstack, `SecRandomCopyBytes` instead of `/dev/urandom` (which iOS
  sandboxes), no controlling TTY.
- `conf.ports :darwin, :posix` picks a gem's `ports/darwin/` when it has one and
  falls back to `ports/posix/` otherwise, resolved per gem at build time.

One consequence shows up in the Ruby you can write. Because
`PICORB_PLATFORM_POSIX` is set, `picoruby-mruby` brings in `mruby-io` and
`mruby-task`, so `puts`, `print`, and `sleep_ms` are available even in the
smallest gem set below.

### One vendored checkout, one build directory

A single `vendor/picoruby` checkout feeds every platform, and all build output
goes to `./build` (`MRUBY_BUILD_DIR`), so the fetched source is never mutated.

```sh
rake setup     # clone PICORUBY_REF into vendor/picoruby (each :lib task depends on this)
rake refresh   # re-fetch PICORUBY_REF into the existing checkout
rake clean     # remove build/ and every example's staged Vendor/
rake clobber   # clean + remove vendor/picoruby
```

| Variable | Default | Controls |
|---|---|---|
| `PICORUBY_REPO` | `https://github.com/bash0C7/picoruby.git` | picoruby source repository |
| `PICORUBY_REF` | `port-darwin` | ref to fetch — see [Vendor source](#vendor-source) |
| `IOS_MIN` | `17.0` | iOS deployment target minimum |
| `WATCHOS_MIN` | `11.0` | watchOS deployment target minimum |
| `PICORUBY_BLE_GEMDIR` | vendor's `picoruby-ble` | alternate picoruby-ble checkout for the BLE examples |
| `MRUBY_CONFIG` | `build_config/r2p2-picoruby-darwin.rb` | build config for the `macos:` host tasks |

## Examples

Every iOS and watchOS example is a SwiftUI app whose behaviour lives in
`app.rb`, shipped as a plain-text resource and compiled at launch by the prism
compiler inside the app. Each has its own README.

| Example | rake namespace | What it demonstrates |
|---|---|---|
| [ios/repl](examples/ios/repl/README.md) | `ios:repl` (also plain `ios`) | evaluate Ruby typed into the app at runtime |
| [ios/networking](examples/ios/networking/README.md) | `ios:net` | `Net::HTTP` over picoruby-socket's darwin port — TLS through mbedTLS, no `URLSession`, no OpenSSL |
| [ios/virtual-peripheral](examples/ios/virtual-peripheral/README.md) | `ios:vperiph` | a BLE GATT peripheral written in Ruby, over CoreBluetooth |
| [ios/iphone-torch](examples/ios/iphone-torch/README.md) | `ios:torch` | the iPhone "Lチカ": the flashlight blinked from a Ruby loop |
| [ios/stackchan](examples/ios/stackchan/README.md) | `ios:stackchan` | a BLE central driving a [Stack-chan](https://github.com/meganetaaan/stack-chan) robot over NUS |
| [ios/tilt-synth](examples/ios/tilt-synth/README.md) | `ios:tiltsynth` | Device Motion to FM synthesis, with the musical mapping in Ruby |
| [watchos/led-toggle](examples/watchos/led-toggle/README.md) | `watchos:led` | a Ruby state machine on the Apple Watch (`arm64_32`) |
| [macos/ls](examples/macos/ls/README.md) | — | a demo script for `rake macos:single` |

Each namespace exposes the same four steps plus an `all` that chains them, and
a `device:` sub-namespace that does the same against connected hardware:

```sh
rake ios:torch:lib            # cross-build libmruby.a, stage it under the example's Vendor/
rake ios:torch:gen            # generate the .xcodeproj from project.yml
rake ios:torch:build          # build for the Simulator
rake ios:torch:run            # boot a Simulator, install, launch
rake ios:torch:all            # all four, in order

rake ios:torch:device:all     # the same pipeline against a connected, signed iPhone
rake ios:torch:device:check   # link for a generic device without signing (no hardware needed)
```

`rake -T` lists every task with its description.

## Running on a device

Device tasks build with automatic signing. Before the first device build:

1. Find your Team ID in Xcode → Settings → Accounts. A free Apple ID works — it
   gives you a Personal Team.
2. In that example's `project.yml`, replace `DEVELOPMENT_TEAM: YOUR_TEAM_ID`
   with your Team ID. If the bundle id collides inside your team, change
   `bundleIdPrefix` too.
3. On the device, trust the certificate once per bundle id: Settings → General
   → VPN & Device Management → your Apple ID → Trust.

Two limits come with a free Personal Team: at most three apps installed at a
time (install error 3002 means you are at the limit — remove one with
`xcrun devicectl device uninstall app --device <UDID> <bundle-id>`), and
provisioning that expires after seven days. The device must also be unlocked
when `device:run` launches the app.

`device:check` needs no hardware at all: it links the app for a generic device
with signing disabled, which surfaces device-SDK-only breakage — an API the
device SDK marks unavailable, or a port symbol missing from the device
archive — without a signing session.

## macOS host

On macOS, picoruby runs natively rather than as an embedded VM, so the host
tasks produce binaries instead of apps. Output lands in `./build/host/bin`.

```sh
rake macos:check                                # Xcode CLT, brew openssl@3, Swift
rake macos:build                                # ./build/host/bin/{r2p2,picoruby}
rake macos:run                                  # the r2p2 shell
rake macos:run APP=path/to.rb                   # run one Ruby file
rake macos:single APP=examples/macos/ls/ls.rb   # a standalone binary with the script embedded
```

The Command Line Tools are enough here; Homebrew's `openssl@3` is needed only
because the host build pulls in the networking gembox. `MRUBY_CONFIG` selects
the build config: `r2p2-picoruby-darwin.rb` is the host base,
`r2p2-picoruby-darwin-ble.rb` adds picoruby-ble and picoruby-picotest, and
`r2p2-picoruby-darwin-single.rb` backs `macos:single`.

A binary built with the BLE config cannot be run by executing
`./build/host/bin/picoruby` directly. macOS TCC aborts (`SIGABRT`) any
CoreBluetooth call from a process that LaunchServices did not start out of an
app bundle declaring `NSBluetoothAlwaysUsageDescription` — signing and prior
authorization make no difference. This repository produces the binary; wrapping
it in such a bundle and launching it with `open -a` belongs to the consumer.
[stackchan-picoruby's `pc/stackchan-pico`](https://github.com/bash0C7/stackchan-picoruby/tree/main/pc/stackchan-pico)
is a worked example.

## Verifying the build

Four checks, from cheapest to most involved.

**`rake smoke`** builds picoruby for the host with
`build_config/r2p2-picoruby-host.rb` — the same core gem set and the same port
chain every iOS config starts from — links `bridge/smoke_test.c` against it, and
runs it. This is the fast gate on the bridge and on `ports/darwin/machine.c`,
and it is what CI runs on every push.

**`rake ios:<name>:device:check`** links the device app unsigned, catching
anything the device SDK forbids that the Simulator and host builds allow.

**`rake ios:<name>:observe`** is the behaviour gate. It launches the built app
on a pinned Simulator `OBSERVE_N` times (default 5) and classifies each run:

- *OK* — the example's expected line appears in the captured output and no new
  crash report landed. The expected line is declared per example in the
  Rakefile's `IOS_EXAMPLES` table (`hello 3` for repl, `[Torch] VM opened` for
  torch, and so on).
- *CRASH* — a new `.ips` report for the app's process, or a known crash
  signature in the output.
- *RUBY_ERROR* — a Ruby backtrace at boot, which leaves the VM open and would
  otherwise let the expected line still appear.

If the runs disagree, the task aborts as NON-DETERMINISTIC: something outside
the build is influencing the result. Raw logs land under `build/observe/`, and
the first OK run is kept as a golden file for later runs to diff against.

The Simulator is pinned by UDID (`SIM_UDID`, defaulted in the Rakefile) so its
container state stays a controlled variable across runs — do not erase or
recreate it. When that UDID is absent, the first available iPhone Simulator is
used and a warning is printed.

**`rake determinism:ios:repl`** attacks the same question from the build side:
it clean-builds `ios-repl`'s `libmruby.a` twice and compares hashes of the
archive's extracted members, ignoring the `ar` header timestamps that change on
every build regardless of code. Equal hashes mean the same inputs really did
produce the same objects.

## How the pieces fit

```
examples/ios/<name>/Sources/*.swift          SwiftUI
        │  bridging header
        ▼
bridge/picoruby_bridge.c                     C bridge
        │
        ▼
Vendor/lib/libmruby.a                        prism compiler + mruby VM,
                                             cross-built from vendor/picoruby by
                                             build_config/r2p2-picoruby-<target>.rb
```

The bridge exposes two shapes, and an example uses one or the other:

- `repl_eval(src)` opens a fresh VM, compiles and runs `src`, and returns the
  captured stdout and stderr — compile diagnostics and uncaught-exception
  backtraces included — as a malloc'd string the caller frees. The `repl`
  example uses this: one clean VM per evaluation.
- `vm_open` / `vm_call` / `vm_close` own a persistent VM. `vm_open` compiles and
  runs the bundled `app.rb`, which assigns the Ruby global `$app`; `vm_call`
  invokes a method on it and returns what that method printed. Every other
  example uses this. Each `vm_call` is dispatched inside an mruby task, so Ruby
  code may block on the VM's own event queue. A single owner thread touches the
  VM for its whole lifetime.

`bridge/task_hal_ios.c` supplies the mruby task-scheduler HAL for iOS and
watchOS, which have no usable SIGALRM timer — it polls instead. That is what
makes `sleep_ms` in Ruby block for a real interval on the device.

Gems link statically: every mrbgem named by the build config is compiled into
`libmruby.a` and nothing is fetched at runtime. A `picoruby-*` gem's C half is
registered when the VM opens, but its Ruby half is a picogem loaded on
`require`, which is why `app.rb` in the BLE examples starts with `require "ble"`
before subclassing `BLE`. To make a class available to an example, add its gem
to that example's build config.

### Two gem-set shapes

**Full REPL** — `mruby-posix` + `core` + `stdlib` + `shell` gemboxes. The whole
Ruby surface, at the cost of a larger link. Used by `repl` and `networking`
(the socket, mbedtls, and rng gems all assume a POSIX-shaped build).

**Reduced** — `conf.picoruby` + `mruby-compiler` + `picoruby-machine`, no
gembox. Core Ruby with `puts` and `print`, but no `stdlib`: `defined?`,
`String#ord`, and `String#%` are absent. Used by `virtual-peripheral`,
`iphone-torch`, `stackchan`, `tilt-synth`, and the watchOS example.

Each example has its own build config, so an example that needs more than the
reduced set adds gems there rather than to anything shared. That is why
`virtual-peripheral` and `stackchan` can use `Array#pack` while `iphone-torch`
cannot. When you bundle new Ruby into an example, try it against `rake smoke`'s
host build before relying on it on a device.

### Compiling a hot method ahead of time

Everything above runs interpreted: prism compiles `app.rb` at launch and the VM
executes it. A method that is hot enough to be worth it can instead be compiled
to native code before the build, with matz's spinel AOT compiler, wrapped into a
PicoRuby mrbgem by [suppify](https://github.com/bash0C7/suppify) and linked in
like any other gem.

The interpreted original stays in the tree as the A/B baseline, and `app.rb`
calls the same method name either way — on the full-mruby VM the generated gem
registers on `kernel_module` when the VM opens, so there is no `require` to add.

The [repl example](examples/ios/repl/README.md#aot-native-kernel) carries a
worked benchmark kernel under `aot-kernel/`. On a physical iPhone 16e the native
version reaches roughly 50× the interpreter once each call does enough work to
amortize the cost of crossing the boundary.

The generated gem is not in the tree. It is regenerated from its Ruby source
before the build, the same way `vendor/picoruby` is fetched rather than
vendored. The step-by-step procedure for applying this to a method of your own
lives in the `aot-embed` skill (`.claude/skills/aot-embed/`).

## Vendor source

The default source is the `port-darwin` branch of
[bash0C7/picoruby](https://github.com/bash0C7/picoruby): upstream master plus
the darwin ports (ble, rng, mbedtls, io-console, machine, socket) and
`hal-io-darwin`, an external HAL provider that replaces `mruby-io`'s posix HAL
for watchOS, whose SDK forbids `fork` and `exec`.

Upstream `picoruby/picoruby` master carries none of those ports. Pointing
`PICORUBY_REF` at it breaks every example that needs a darwin port first:
`networking` (its TLS would want OpenSSL, which iOS does not ship),
`virtual-peripheral`, `stackchan`, and the watchOS build. Any fork or branch
carrying the ports works — `PICORUBY_REF` re-points the whole vendored tree, and
nothing here is pinned to a single ref.

## Layout

```
R2P2-darwin/
  Rakefile               check / setup / refresh / smoke / ios:<example>:* /
                         watchos:led:* / determinism:* / clean / clobber
  rakelib/macos.rake     macos:check / macos:build / macos:run / macos:single
  build_config/
    r2p2-picoruby-ios-<example>-{sim,device}.rb    per-example iOS cross-builds
    r2p2-picoruby-watchos-{sim,device}.rb          watchOS cross-builds
    recompile_arm64_32.rb                          arm64_32 re-archive for the watch
    r2p2-picoruby-darwin{,-ble,-single}.rb         macOS host builds
    r2p2-picoruby-host.rb                          host build behind `rake smoke`
    r2p2-picoruby-ios-{rng,mbedtls,io-console}-sim.rb
                                                   single-gem darwin-port probes (no rake
                                                   task; see below)
    r2p2-stackchan-pc.rb                           host build for stackchan-picoruby's PC side
  bridge/                picoruby_bridge.{c,h}, task_hal_ios.c, smoke_test.c
  examples/
    ios/<name>/          SwiftUI app + app.rb (+ example-local gems where used)
    watchos/led-toggle/  the watchOS example
    macos/ls/            demo script for rake macos:single
  vendor/picoruby/       fetched by rake setup (gitignored)
  build/                 all build output, MRUBY_BUILD_DIR (gitignored)
```

The three single-gem probe configs each cross-build the bare VM plus exactly one
gem, to check that gem's darwin port compiles and links for the iOS SDK in
isolation. They back no rake task; drive the vendored tree directly, the same
way every `:lib` task does:

```sh
cd vendor/picoruby
MRUBY_BUILD_DIR=../../build \
MRUBY_CONFIG=$(cd ../.. && pwd)/build_config/r2p2-picoruby-ios-rng-sim.rb \
  rake
```

## Verified environment

| | Verified with |
|---|---|
| macOS | 26.5 |
| Xcode | 26.5 (17F42) |
| Ruby | 4.0.5 |

Device builds have been exercised against a physical iPhone (`arm64`) and an
Apple Watch (`arm64_32`) signed with a free Apple ID Personal Team.

## License

[MIT](LICENSE)
