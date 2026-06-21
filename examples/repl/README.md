# repl — evaluate Ruby on the device

A SwiftUI app (`PicoRubyRunner`) with a text editor, a Run button, and an output
view. It compiles and runs whatever Ruby you type, on the device, and shows the
captured output.

## Where PicoRuby runs

There is no bundled `.rb` in this example — **the Ruby is what you type at
runtime**. The cross-built `libmruby.a` carries the prism compiler inside the VM,
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

`repl_eval(const char *src)` (see `../../bridge/picoruby_bridge.h`) opens a fresh
VM, compiles and runs `src`, and returns the captured stdout+stderr as a string.
A new VM per Run means each evaluation starts clean. `ContentView.run()` calls it
on a background thread and frees the returned string.

## Files

| File | Role |
|---|---|
| `Sources/App.swift` | the `@main` app entry; one `WindowGroup` |
| `Sources/ContentView.swift` | editor + Run + output; calls `repl_eval` |
| `Sources/PicoRubyRunner-Bridging-Header.h` | exposes the C bridge to Swift |
| `project.yml` | xcodegen project (links `-lmruby`, the staged `libmruby.a`) |

The Ruby VM, the bridge, and the build configs live one level up (`../../bridge`,
`../../build_config`); this directory is only the app.

## Run it

```
rake ios                  # Simulator: lib -> gen -> build -> run (headless)
rake ios:device:all       # connected device: build, sign, install, launch
```

`EXAMPLE` defaults to `repl`, so the base `ios:*` tasks build this app.

## What you can type

The VM uses a reduced gem set (no `core`/`stdlib`, no POSIX), so the Ruby surface
is smaller than full mruby/CRuby: integer/float math, `String`, interpolation,
`print`/`p`, `raise`. `puts` is not in the reduced VM, so the bridge installs a
small `puts` shim defined in terms of core `print`. File IO, networking, and the
rest of stdlib are absent. See the repository README's "Constraints worth
knowing" for the full picture.
