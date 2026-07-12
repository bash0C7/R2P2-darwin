# repl — evaluate Ruby on the device

日本語版: [README_jp.md](README_jp.md)

A SwiftUI app (`PicoRubyRunner`) with a text editor, a Run button, and an output
view. It compiles and runs the Ruby you type, on the device, and shows the
captured output.

## Where PicoRuby runs

There is no bundled `.rb` in this example — the Ruby is what you type at
runtime. The cross-built `libmruby.a` carries the prism compiler inside the VM,
so the source is compiled and run on the device itself, not ahead of time.

Each Run goes through one bridge call:

```
ContentView (TextEditor + Run)
        │  repl_eval(source)            bridge/picoruby_bridge.c
        ▼
  fresh single-use PicoRuby VM         prism compiles the source, the VM runs it
        │  captured stdout + stderr     (uncaught exceptions surface as a backtrace
        ▼                               string instead of crashing the app)
  String shown in the output view
```

- `repl_eval(const char *src)` (`../../../bridge/picoruby_bridge.h`) opens a
  fresh VM, compiles and runs `src`, and returns the captured stdout+stderr —
  compile diagnostics and uncaught-exception backtraces included — as a
  malloc'd string the caller must free.
- A new VM per Run means each evaluation starts clean.
- `ContentView.run()` calls it on a background thread and frees the returned
  string; a NULL return (allocation/setup failure) is shown as
  `(VM failed to start)`.

## Files

The Ruby VM, the bridge, and the build configs live at the repo root
(`../../../bridge`, `../../../build_config`); this directory is only the app.

- `Sources/App.swift` — the `@main` app entry; one `WindowGroup`.
- `Sources/ContentView.swift` — editor + Run + output; calls `repl_eval`.
- `Sources/PicoRubyRunner-Bridging-Header.h` — exposes the C bridge to Swift.
- `project.yml` — xcodegen project; compiles the bridge sources and links
  `-lmruby` (the staged `libmruby.a` under `Vendor/lib`).

## Run it

The app runs on the iOS Simulator and on a connected device.

```
rake ios                  # Simulator: lib -> gen -> build -> run (headless)
rake ios:device:all       # connected, signed device: lib -> gen -> build -> run
```

`EXAMPLE` defaults to `repl`, so the base `ios:*` tasks build this app.

## What you can type

The VM is built by `build_config/r2p2-picoruby-ios-repl-{sim,device}.rb` with
the full-REPL gem set, so the full `core`/`stdlib` Ruby surface is available.

- Gemboxes: `mruby-posix` + `core` + `stdlib` + `shell`, with Darwin ports
  preferred over their POSIX siblings (`conf.ports :darwin, :posix`).
- Networking gems and OpenSSL are excluded from this build config.
- The bridge prepends a one-line `puts` shim (defined via core `print`) to
  every eval; it is one physical line, so line numbers in diagnostics shift by
  exactly 1 relative to what you typed.
- See the repository README's "Constraints worth knowing" for the full picture.
