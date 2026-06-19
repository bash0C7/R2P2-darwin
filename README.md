# R2P2-macOS

An environment for building and running standard PicoRuby / R2P2 on a macOS host.

## What this is

R2P2-macOS is the macOS target among the repositories that port PicoRuby's
shell and runtime (the picoruby-r2p2 gem) to different platforms. Ports are
split by operating system, so this is the macOS one; an iOS target would be
R2P2-iOS. It mirrors how R2P2-ESP32 targets the ESP-IDF chip family, except the
axis here is the OS. The mruby build is named host and its platform is posix,
following the upstream convention.

This repository is a build-and-run harness. It does not contain port source
code. PicoRuby itself is fetched from upstream at build time.

## Design

- PicoRuby is fetched from GitHub upstream (picoruby/picoruby) by `rake setup`
  into vendor/picoruby. No submodule, no sibling checkout. vendor/picoruby is
  gitignored.
- Build output is redirected to ./build via MRUBY_BUILD_DIR, so the fetched
  picoruby source stays pristine.
- Mac-native capabilities (BLE/CoreBluetooth and others) are added as mrbgems
  instead of by modifying upstream, which also keeps the capability surface
  small.

## Requirements

- macOS on Apple Silicon
- rbenv with Ruby 4.0.5 (pinned in .ruby-version; the upstream build.rb requires
  Ruby >= 2.7)
- Homebrew openssl@3 (`brew install openssl@3`; the networking gembox links
  ssl/crypto)
- A Swift 6.3+ toolchain, for the BLE build only (it compiles a CoreBluetooth
  backend)
- git

## Usage

```
rake setup        fetch picoruby/picoruby into vendor/picoruby (PICORUBY_REF selects a ref, default master)
rake build        build standard r2p2 + picoruby into ./build/host
rake run          start the r2p2 shell (rake run APP=path/to.rb runs a Ruby file)
rake build:ble    build picoruby-ble with the Darwin/CoreBluetooth port into ./build-ble
rake run:ble APP=path/to.rb   run a Ruby file on the BLE runtime
rake clean        remove build outputs
rake clobber      also remove vendor/picoruby
```

To pin a release tag for reproducibility: `PICORUBY_REF=3.4.2 rake setup`.

To build and verify a port branch from a fork instead of upstream:
`PICORUBY_REPO=<fork url> PICORUBY_REF=<branch> rake refresh build:ble`.

## Layout

```
R2P2-macOS/
  Rakefile            setup (fetch) / build / build:ble / run / clean / clobber
  build_config/
    common.rb         VM defines shared by every runtime
    default.rb        standard host (posix) build: r2p2 + picoruby runner + networking
    ble.rb            BLE host build: adds picoruby-ble with the Darwin port
  test/ble-darwin/    verification for the BLE Darwin port
  docs/               BLE Darwin port design notes and the device E2E procedure
  vendor/picoruby/    fetched from upstream by rake setup (gitignored)
  build/, build-ble/  build output, MRUBY_BUILD_DIR (gitignored)
```

## BLE / CoreBluetooth

`rake build:ble` links picoruby-ble together with its Apple/Darwin port, which
drives CoreBluetooth and synthesizes the byte events the gem's decoder expects.
The port source lives in the picoruby tree (proposed upstream), not here; this
repository builds and verifies it. See docs/ for the design and the device E2E
procedure, and test/ble-darwin/ for the runnable checks.
