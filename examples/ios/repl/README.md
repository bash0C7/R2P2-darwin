# repl — evaluate Ruby on the device

日本語版: [README_jp.md](README_jp.md)

A SwiftUI app (`PicoRubyRunner`) with a text editor, a Run button, and an output
view. Whatever Ruby you type is compiled and executed on the device, and the
captured output comes back on screen.

This is the entry-point example: the bare `ios:*` rake tasks are aliases of
`ios:repl:*`, so `rake ios` builds and launches this app.

## How it works

There is no bundled `.rb` here — the Ruby is what you type at runtime. The
cross-built `libmruby.a` carries the prism compiler inside the VM, so the source
is compiled on the device itself rather than ahead of time on the Mac.

Each Run is one bridge call:

```
ContentView (TextEditor + Run)
        │  repl_eval(source)                  bridge/picoruby_bridge.c
        ▼
  a fresh single-use PicoRuby VM              prism compiles the source, the VM runs it
        │  captured stdout + stderr           an uncaught exception is printed as a
        ▼                                     backtrace rather than crashing the app
  String shown in the output view
```

- `repl_eval(const char *src)` (declared in `../../../bridge/picoruby_bridge.h`)
  opens a fresh VM, compiles and runs `src`, and returns everything written to
  stdout and stderr — compile diagnostics and uncaught-exception backtraces
  included — as a malloc'd string the caller must free.
- Output capture redirects file descriptors 1 and 2 into a temporary file for
  the duration of the call, so anything the VM or a C gem writes is caught, not
  just Ruby-level `print`.
- A new VM per Run means every evaluation starts from a clean slate. The VM's
  heap is allocated per call and released wholesale when the call returns.
- `ContentView.run()` calls it on a background thread and frees the returned
  string. A NULL return — allocation or VM setup failure — is displayed as
  `(VM failed to start)`.

The app also runs once on appear, so a fresh launch already shows the result of
the default snippet without a tap. That is what makes
`rake ios:repl:observe` able to check for `hello 3` in a launch's console
output.

## Files

The VM, the C bridge, and the build configs live at the repository root
(`../../../bridge`, `../../../build_config`); this directory is only the app.

- `Sources/App.swift` — the `@main` entry point; one `WindowGroup`.
- `Sources/ContentView.swift` — editor, Run button, output view; calls `repl_eval`.
- `Sources/PicoRubyRunner-Bridging-Header.h` — exposes the C bridge to Swift.
- `project.yml` — the xcodegen project: compiles the bridge sources and links
  `-lmruby` against the staged `libmruby.a` under `Vendor/lib`.
- `aot-kernel/bench_tick.{rb,rbs}` — the AOT kernel: one source of truth for
  both the interpreted baseline and the native build. See
  [AOT native kernel](#aot-native-kernel).
- `picoruby-bench_tick/` — the generated mrbgem. Not in the tree; it is
  gitignored and regenerated from `aot-kernel/`.

`Vendor/` is produced by `rake ios:lib` and is not a source directory.

## Build and run

### Simulator

```sh
rake ios          # lib -> gen -> build -> run
```

Type an expression and tap Run.

### Device

Before the first on-device build, replace `DEVELOPMENT_TEAM: YOUR_TEAM_ID` in
`project.yml` with your own Team ID — see
[Running on a device](../../../README.md#running-on-a-device).

```sh
rake ios:device:all
```

## AOT native kernel

Alongside the interpreter, this example runs one Ruby method as native code
compiled ahead of the build, so the two can be benchmarked against each other.
`bench_tick` (`aot-kernel/bench_tick.{rb,rbs}`) is compiled by matz's
[spinel](https://github.com/matz/spinel) and wrapped into the
`picoruby-bench_tick` mrbgem by
[suppify](https://github.com/bash0C7/suppify).

The seed in `Sources/ContentView.swift` first checks that the interpreted and
native versions agree, then sweeps the per-call batch size `n`. On a physical
iPhone 16e the native version reaches roughly 50× once each call does enough
work to amortize the cost of crossing the VM boundary — dispatch, argument
check, and spinel's `setjmp`. The interpreter stays roughly flat across the
sweep.

### Regenerating the gem

`picoruby-bench_tick/` is **not in the repository**. It is gitignored and
regenerated from the kernel source, the same way `vendor/picoruby` is fetched
rather than vendored. Generation is deterministic for a given spinel and suppify
version, so the gem is a build product, not source.

spinel and suppify are external tools, located the way you would locate a
compiler:

```sh
cd examples/ios/repl/aot-kernel
SPINEL=/path/to/spinel/spinel SPINEL_LIB=/path/to/spinel/lib \
  ruby /path/to/suppify/suppify.rb bench_tick.rb -o bench_tick -t picoruby -d ..
#   -> ../picoruby-bench_tick/
```

`rake ios:repl:lib` links the gem in through one `conf.gem` line in the build
config, so regenerate it before building. The full apply-and-embed procedure —
including how to do this for a method of your own — is in the `aot-embed` skill
(`.claude/skills/aot-embed/`).

## What Ruby is available

This example is built by `build_config/r2p2-picoruby-ios-repl-{sim,device}.rb`
with the full-REPL gem set, so the complete `core` and `stdlib` surface is
present — the widest of any example in this repository.

Gemboxes: `mruby-posix` + `core` + `stdlib` + `shell`. Networking is not in
there — for HTTP and TLS from Ruby, see the
[networking example](../networking/README.md), which links the socket and
mbedTLS stack on top of this same gem set.
