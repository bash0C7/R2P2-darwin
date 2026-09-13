# PicoRuby iOS — Core capability + Stack-chan BLE controller example

Date: 2026-06-21
Status: Design approved (brainstorming complete; pending spec review → plan)

## Purpose

Turn R2P2-iOS from a single REPL test app into a reusable **PicoRuby-on-iOS
substrate** plus a first **real, App-Store-shippable** example: an iOS app that
controls a Stack-chan robot over BLE, where the control logic is written in
Ruby and runs inside the embedded PicoRuby VM on a physical iPhone.

The guiding principle, set by the user:

> **Maximize Ruby; restrict Swift to glue (the picoruby-ble CoreBluetooth
> backend + the C bridge) and the UI layer.** Zero-Swift is the ideal but is
> impossible, so glue and UI are the accepted Swift compromise. Everything else
> — control logic, BLE orchestration, frame encoding — lives in Ruby.

And the layering principle:

> The Stack-chan app is **one example bundled in R2P2-iOS**. Whatever is
> **commonly needed by any PicoRuby iOS app** — the common ground between the
> REPL and this app — is elevated to R2P2-iOS's **core (main) capability**,
> not example-specific code.

This is a single unified design (no sub-spec split). The implementation plan
sequences it in four phases, but the vision is one coherent feature.

## Non-goals (v1)

- Audio/TTS (`say`), AI `chat`, on-device touch streaming beyond a simple
  notify handler — deferred. v1 commands are face, LED, head/servo, torque.
- BLE background mode (`bluetooth-central`) — v1 is foreground-only.
- Multi-device picker UI — v1 connects to the first `StackChan-PicoRuby` match.
- App Store submission itself — v1 ships to a physical device via free Personal
  Team signing; the design keeps submission viable (see §2.5.2) but submitting
  is out of scope.
- A mock BLE backend for CI — manual device testing is the integration gate.

## Architecture overview

```
examples/stackchan (SwiftUI)        examples/repl (SwiftUI)
  buttons → command queue             text field → repl_eval(src)
        │                                   │
        ▼                                   ▼
  ┌─────────────────────── R2P2-iOS core ───────────────────────┐
  │ VM lifecycle bridge:                                         │
  │   repl_eval(src)            (fresh VM per call — REPL)        │
  │   vm_open() / vm_call(...) / vm_close()  (persistent VM)     │
  │ stdout/stderr capture · task HAL (polling) · output strings  │
  │ libmruby.a  (iphonesimulator AND iphoneos cross-builds)      │
  │ Swift↔Ruby glue pattern for native-backed gems              │
  └──────────────────────────────────────────────────────────────┘
        │ (stackchan example only)
        ▼
  picoruby-ble (iOS-adapted port)  ──  PicoBLEDarwin (Swift / CoreBluetooth)
        │  <F:2>\n  via NUS RX 6e400002
        ▼
   Stack-chan (BLE peripheral "StackChan-PicoRuby")
```

## Components

### A. R2P2-iOS core (main capability)

The current repo couples "REPL app" with "cross-build harness". Split into a
reusable core consumed by examples.

1. **Cross-build of `libmruby.a`** (existing) extended to two SDKs:
   - `build_config/r2p2-picoruby-ios-sim.rb` — `iphonesimulator` (existing)
   - `build_config/r2p2-picoruby-ios-device.rb` — `iphoneos`, arm64 device (new)
   Both keep the load-bearing reduced gem set and the build-wide ABI defines
   documented in HANDOFF.md (no POSIX; `MRB_CONSTRAINED_BASELINE_PROFILE`/
   `MRB_HEAP_PAGE_SIZE` are injected build-wide by picoruby's mrbgem.rake and
   must stay mirrored in each app target's `GCC_PREPROCESSOR_DEFINITIONS`).

2. **VM lifecycle bridge** — generalize today's fresh-VM-per-eval bridge to
   offer both models from one C API (`bridge/picoruby_bridge.{c,h}`):
   - `char *repl_eval(const char *src)` — current behavior (fresh zeroed heap,
     open → run → close, capture stdout/stderr). Used by the REPL example.
   - Persistent VM:
     - `void *vm_open(void)` — allocate heap, `mrb_open_with_custom_alloc`,
       load the bundled `app.rb`, return an opaque handle. The VM stays alive.
     - `char *vm_call(void *vm, const char *method, const char *json_args)` —
       invoke a top-level Ruby entry point (e.g. a global dispatcher method)
       with a small string/JSON payload; return captured output. All `mrb_*`
       calls happen on the single owner thread (see §E concurrency).
     - `void vm_close(void *vm)` — `mrb_close` + free heap.
   - Output capture (fd redirection) and the polling task HAL (`task_hal_ios.c`)
     are reused unchanged. The mruby-task exception-detection rule
     (`mrb_task_value` + `mrb_exception_p`, not `mrb->exc`) is preserved.

3. **Swift↔Ruby glue pattern for native-backed gems** — the harness gains a
   documented, reusable way to cross-build a picoruby gem whose backend is
   native Swift (CoreBluetooth here): the gem's Ruby+C compiles into
   `libmruby.a` via a gembox; the Swift backend compiles into the consuming app
   target; the C↔Swift boundary is the gem's `@c` exports + generated header.
   picoruby-ble is the first user of this pattern; the pattern itself is core.

### B. Examples (bundled under `examples/`)

- `examples/repl/` — the current REPL app ("test版"), kept for dev/smoke. Wired
  to `repl_eval`. This is where arbitrary user-Ruby lives (and is the only
  2.5.2-risky surface — see §2.5.2).
- `examples/stackchan/` — the new Stack-chan controller. Persistent VM running a
  bundled `app.rb`; SwiftUI buttons; picoruby-ble transport.

### C. picoruby-ble iOS adaptation (the glue)

Fork/adapt `picoruby-ble-darwin-port` (≈70% reusable; CoreBluetooth APIs are
identical on iOS). Vendored under R2P2-iOS and consumed by the stackchan example.

- `Package.swift`: add `.iOS(.v13)` to `platforms` (keep `.macOS`).
- **Link model**: compile the `PicoBLEDarwin` Swift backend directly into the
  app target (xcodegen sources), not a dylib. The picoruby-ble Ruby+C goes into
  `libmruby.a` via the gembox. C↔Swift via existing `@c` exports + header.
- **Info.plist**: `NSBluetoothCentralManagerUsageDescription` (mandatory on iOS;
  install is rejected without it).
- **Threading**: keep the port's model — CoreBluetooth callbacks on a private
  serial queue push BTstack-format packets into a thread-safe FIFO; the VM owner
  thread drains one-per-tick. This is exactly the §E agent-thread model.
- **Gembox parity**: adding picoruby-ble must NOT re-introduce the
  POSIX/IO/machine gems that fail to link on iOS. Verify the gem's deps are
  iOS-safe; drop or stub anything POSIX.

### D. The Stack-chan control Ruby (`examples/stackchan/app.rb`)

Reuse the PC CLI's pure-Ruby layer **almost verbatim**:
`frame_codec.rb`, `send_builder.rb`, `face_table.rb`, `led_color_table.rb` from
`stackchan-picoruby/pc/stackchan/lib/stackchan/ble/`.

- **Only the transport layer changes**: the PC uses `rb-corebluetooth-mac`; iOS
  uses picoruby-ble's central API. The frame layer is shared.
- `Stackchan` class methods build a frame via the shared codec and write it to
  NUS RX `6e400002-…` via
  `write_value_of_characteristic_without_response`:
  - `face(sym)` → `<F:index>\n` (neutral/smile/joy/surprised/sad/angry → 0–5)
  - `led(side, color, mode)` → `<L:1,R:r,G:g,B:b,S:side,M:mode>\n`
    (side B/L/R — note the wire reverses left/right; mode s/b/p/o)
  - `head(yaw:, pitch:, time_ms:)` → `<YL:n,T:t>\n` / `<YR:n,PU:p,T:t>\n`
  - `torque(on)` → `<torque:on>\n` / `<torque:off>\n`
- After connect: discover services, bind NUS service/RX/TX, subscribe TX to
  receive frame ACKs (`.` success / `?` error) and async `<touch:zone>\n`.
- **Constraint to verify in the plan**: the reused codec must run on the reduced
  VM (core `String`/`Array`/`Hash`/`sprintf %` only). Any stdlib dependency is
  ported minimally or rewritten. This is an explicit plan task, not an assumption.

### E. Concurrency model (load-bearing)

mruby is single-threaded: **all `mrb_*` calls happen on one owner thread.**

- One background "agent" thread owns the persistent VM. Ruby's main loop, each
  tick: (1) drains a thread-safe command queue that Swift button taps push into,
  (2) pumps BLE events (picoruby-ble `start`-style polling of the FIFO),
  (3) handles ACK/notify.
- Swift UI is thin: enqueue commands (e.g. `{"cmd":"face","arg":"joy"}`) and
  subscribe to connection-state updates. No `mrb_*` on the UI thread.
- The rejected alternative — per-tap `mrb_funcall` from arbitrary threads —
  races with BLE callbacks on the VM and collapses into this model with worse
  safety. Not used.

### F. Connection UX (stackchan example)

- Explicit **Connect** button → scan for name prefix `StackChan-PicoRuby` →
  connect first match → subscribe TX. (User-initiated, so the iOS BLE permission
  prompt fires on a user action.)
- Display connection state: disconnected / scanning / connected. Reconnect on
  drop. Single device assumption for v1.

### G. On-device build & signing (new core capability)

R2P2-iOS is simulator-only today; add device build to core.

- `build_config/r2p2-picoruby-ios-device.rb` — `xcrun --sdk iphoneos`, arm64.
- `examples/*/project.yml` signing: `CODE_SIGN_STYLE: Automatic`,
  `DEVELOPMENT_TEAM` (free Personal Team), bundle id, Info.plist (BLE usage
  string for stackchan).
- Rake: `ios:device:lib`, `ios:device:build`
  (`-destination 'generic/platform=iOS'`), `ios:device:run` (`xcrun devicectl`
  install + launch on the connected device).
- **Human-only steps** (cannot be automated — interactive auth / physical):
  connect+trust the iPhone; sign into the Apple ID / select the Personal Team in
  Xcode once. Free Personal Team builds expire after 7 days and require the
  device registered.

## Guideline 2.5.2 compliance

The stackchan app is 2.5.2-free: `app.rb` and all control Ruby are **bundled,
fixed, not user-editable, not downloaded; there is no REPL or code-input field**.
PicoRuby is purely the implementation language for the app's own fixed behavior,
and mruby is a **bytecode interpreter with no JIT** (so the iOS JIT prohibition
is also not implicated). This is the accepted "embedded interpreter implementing
the app's own functionality" pattern. The 2.5.2-risky surface (arbitrary user
Ruby) lives only in the separate `examples/repl` app, not in this one.

## Testing strategy

- **Host smoke** (extend existing `rake smoke`): build the control Ruby on the
  host VM and assert it emits correct frames (`<F:2>\n`, `<L:1,...>\n`,
  `<YL:50,T:500>\n`, torque, etc.). Reuse the frame-format expectations from
  `pc/stackchan/test/test_ble_*.rb`. Pure logic, no BLE.
- **Build verification**: `rake ios:lib` (sim) and `ios:device:lib` (device)
  both produce a linking `libmruby.a` with picoruby-ble; both example apps build.
- **BLE integration**: requires a physical Stack-chan + physical iPhone (the
  Simulator has no BLE radio) → **manual human verification**: Connect, tap each
  face/LED/head/torque button, observe the robot react and the ACK path.

## Implementation phases (sequenced; one plan)

1. **Core refactor** — persistent-VM bridge (`vm_open/vm_call/vm_close` beside
   `repl_eval`) + `examples/` layering. Verify with the REPL app and a trivial
   persistent-VM example. No BLE.
2. **On-device build + signing** — device build_config + rake tasks + signed
   project.yml. Verify by installing the REPL on a physical iPhone.
3. **picoruby-ble iOS port adaptation** — Package.swift iOS platform, link into
   an app target, Info.plist BLE string, gembox parity. Verify a minimal example
   can scan and discover the Stack-chan.
4. **Stack-chan example** — `app.rb` reusing the PC codec, SwiftUI buttons,
   connect UX, command queue, ACK/touch handling. Verify on the physical robot.

## Key references

- HANDOFF.md — existing iOS build findings (reduced gem set, ABI defines,
  task HAL, exception detection) that the core must preserve.
- `stackchan-picoruby/pc/stackchan/lib/stackchan/ble/` — frame_codec,
  send_builder, face_table, led_color_table (reused), client.rb (transport,
  replaced), and `app/application.rb:597+` (device-side dispatcher contract).
- BLE protocol: NUS service `6e400001-…`, RX `6e400002-…`, TX `6e400003-…`;
  ASCII frames terminated `\n`; ACK `.`/`?`; no pairing.
- `picoruby-ble-darwin-port/mrbgems/picoruby-ble/` — Swift CoreBluetooth backend
  (`ports/darwin/ext/.../PicoBLECentral.swift`), C glue, Ruby central API
  (`mrblib/ble_central.rb`); `Package.swift:9` platform line to extend.
