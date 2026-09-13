# Virtual BLE Peripheral example — Design

**Goal:** A third R2P2-iOS example: a configurable virtual BLE *peripheral* test
stub, **PicoRuby-first**. It advertises a GATT profile, accepts a central's
connect/read/write/subscribe, auto-responds, and streams every event as a
human-readable line into a read-only scrolling log. It exists to make debugging
BLE *central* code easier — primarily the PC `stackchan`
(`github.com/bash0C7/stackchan-picoruby/pc/stackchan`).

**Thesis it proves:** you can build this class of app **PicoRuby-first** on iOS —
the GATT profile *and* the per-event behavior live in Ruby (`app.rb`); Swift is
only the CoreBluetooth radio + the C bridge + a minimal UI.

---

## Why a new example (not an extension of stackchan)

stackchan is a BLE **central** (it connects *to* a robot). This example is the
opposite role: a BLE **peripheral** (it is connected *to*). The PC `stackchan`
is a central that scans, connects, writes ASCII frames to a write
characteristic, and subscribes to a notify characteristic — so to debug it
without the physical robot you need a *peripheral* to connect to. LightBlue's
"Virtual Peripheral" feature is what the user used manually (screenshot: name
`PBLE-TEST`, Heart Rate service `0x180D` with Notify/Read/Write characteristics);
this example replaces that manual tool with a Ruby-defined, editable one.

## Hard constraint (load-bearing)

**The picoruby-ble Darwin port is central-only.** Its `pble_*` exports are all
central; the peripheral C functions (`BLE_peripheral_advertise/notify/...`) are
no-op stubs (confirmed in the port's `ble_peripheral.c` and its README: "Central
and observer only"). Therefore PicoRuby's `BLE.new(:peripheral)` API does nothing
on Darwin, and the peripheral **must** be implemented in Swift
(`CBPeripheralManager`).

**That Swift peripheral lives in this example's `Sources/` — never in the
picoruby-ble Darwin port.** Putting an iOS peripheral implementation into the
`bash0C7/picoruby` fork (the darwin-port worktree) is a cross-repo
responsibility violation and is categorically disallowed. All iOS glue lives in
R2P2-iOS, consistent with the repo's ports model.

## Naming

- Directory: `examples/virtual-peripheral/`
- Xcode target / scheme: `VirtualPeripheral`
- Bundle id: `com.bash0c7.picoruby.VirtualPeripheral`
- Rake namespace: `ios:vperiph:*`
- Default advertised BLE local name: `PBLE-TEST`

## Architecture

```
   PC stackchan (BLE central)  ──connect/write/subscribe──▶  iPhone
                                                              │
   ┌──────────────────────────────────────────────────────────────────┐
   │ VirtualPeripheral.app                                              │
   │                                                                    │
   │  Swift (Sources/)                    PicoRuby (app.rb, persistent  │
   │  ───────────────────                 VM) = brain                   │
   │  PeripheralManager.swift   ── vm_call ─▶  profile table (data):     │
   │   CBPeripheralManager                     name, services[],        │
   │   - build GATT from profile               characteristics[]        │
   │   - advertise PBLE-TEST              ◀──  serialized profile        │
   │   - route didReceiveRead/Write,                                    │
   │     subscribe, (dis)connect ── vm_call ─▶  event handlers:         │
   │   - respond to central with               - on_read  → value+log   │
   │     value returned by VM            ◀──   - on_write → resp+log    │
   │   - append log line to @Published          - on_subscribe → log    │
   │                                            - tick → notify(s)+log   │
   │  VMExecutor.swift (serial VM owner, 1Hz tick)                      │
   │  ContentView.swift (read-only scrolling log)                      │
   │  App.swift, bridging header                                        │
   └──────────────────────────────────────────────────────────────────┘
```

### Responsibility split

**PicoRuby (`app.rb`) — the brain, where the proof lives:**
- Declares the GATT profile **as data**: name, services (uuid), characteristics
  (uuid, properties = read/write/notify, initial value, behavior tag).
- Two profiles are defined as data; **one is active, chosen by a constant at the
  top of `app.rb`** (`ACTIVE_PROFILE`). No runtime switching (YAGNI) — to switch,
  edit one line and relaunch.
  1. **`:heart_rate`** (default, matches the LightBlue screenshot):
     Heart Rate service `0x180D` with
     - Heart Rate Measurement `0x2A37` — Notify (synthetic bpm pushed on tick
       while subscribed)
     - Body Sensor Location `0x2A38` — Read (canned value)
     - Heart Rate Control Point `0x2A39` — Write (logged, accepted)
  2. **`:nus`** (for PC stackchan): Nordic UART Service
     `6e400001-b5a3-f393-e0a9-e50e24dcca9e` with
     - RX `6e400002-...` — Write: each ASCII frame is logged; auto-reply `.`
       (ACK_OK) is notified on TX. A `<read:pos>` write replies with a canned
       detail frame `<YL_actual:0,PU_actual:50>\n`.
     - TX `6e400003-...` — Notify (carries the ACK / detail frames)
- Per-event handlers return `(response_value, log_line)`. Handlers stay within
  the reduced PicoRuby VM surface (no `defined?`, no `Array#pack`, no `Regexp`;
  hex built/parsed by hand — same discipline as stackchan's `FrameCodec`).

**Swift — radio + bridge + minimal UI only:**
- `PeripheralManager.swift`: owns `CBPeripheralManager`. On power-on it asks the
  VM for the active profile, builds the `CBMutableService`/`CBMutableCharacteristic`
  tree, and starts advertising the profile's name (`PBLE-TEST`). It forwards
  `didReceiveRead`, `didReceiveWrite`, subscribe/unsubscribe, and connect/
  disconnect to the VM, responds to the central with the value the VM returns,
  and appends the VM's log line to a published log string. A 1 Hz tick asks the
  VM for any notifications to push (e.g. the synthetic heart-rate value while a
  central is subscribed).
- `VMExecutor.swift`: persistent VM owner copied from stackchan — one serial
  `DispatchQueue` owns the VM (`vm_open`/`vm_call`/`vm_close`); a 1 Hz timer
  posts `vm_call("tick","")`. No `mrb_*` off that thread.
- `ContentView.swift`: a **read-only** scrolling log
  (`ScrollView { Text(log).textSelection(.enabled) }`, newest pinned). Read-only
  display means **no software keyboard ever appears**, which is the direct,
  simplest satisfaction of "tapping the textbox must not leave the keyboard
  stuck". As defensive belt-and-suspenders the REPL keyboard-dismiss pattern
  (`@FocusState` + `.onTapGesture { focused = false }` + a keyboard-toolbar
  "Done") is applied, but there is no text input in v1.
- `App.swift`, `VirtualPeripheral-Bridging-Header.h` (`#import "picoruby_bridge.h"`).

### Bridge seam (String-only / NUL-safe)

`vm_call(vm, method, arg)` passes one String and returns a NUL-terminated
`char*`, so binary characteristic values (e.g. Heart Rate Measurement bytes,
which can contain `0x00`) cannot cross it raw. **All characteristic values cross
the bridge hex-encoded** (PicoRuby emits lowercase hex ASCII; Swift decodes to
`Data`, and encodes incoming write values to hex before calling in). NUS frames
are ASCII but are hex-encoded too, uniformly. The seam:

| call | arg | returns |
|---|---|---|
| `profile` | `""` | serialized GATT table (see format below) |
| `on_read` | `"<char_uuid>"` | `"<value_hex>\|<log_line>"` |
| `on_write` | `"<char_uuid>\|<value_hex>"` | `"<resp_char_uuid>:<resp_hex>\|<log_line>"` (resp part empty if none) |
| `on_subscribe` / `on_unsubscribe` | `"<char_uuid>"` | `"<log_line>"` |
| `on_connect` / `on_disconnect` | `""` | `"<log_line>"` |
| `tick` | `""` | zero or more lines `"<char_uuid>:<value_hex>\|<log_line>"`, `\n`-separated (empty string if nothing to push) |

**Profile serialization** (one line per element, simple delimited ASCII; parsed
by Swift):
```
NAME PBLE-TEST
SERVICE 180d
CHAR 2a37 notify
CHAR 2a38 read
CHAR 2a39 write
```
(16-bit UUIDs emitted as 4 hex chars; 128-bit as the full dashed form. Swift
expands a 4-hex UUID to the Bluetooth base UUID.)

## Build / ports

- **No picoruby-ble** — BLE is entirely Swift CoreBluetooth, so this example
  needs only the minimal reduced VM plus the persistent-VM bridge API (which is
  in `bridge/picoruby_bridge.c`, gem-independent). It **reuses the base
  build-configs** `build_config/r2p2-picoruby-ios-{sim,device}.rb`. No new
  build-config, no mbedtls/cyw43/BLE dependencies, no `PicoBLEDarwin` package.
- `project.yml`: based on `examples/repl/project.yml` (base ABI defines,
  `HEADER_SEARCH_PATHS` pointing at `build/ios-sim/include`, `-lmruby`), plus:
  - `app.rb` as a `resources` build phase (bundled, like stackchan).
  - `Info.plist` keys `NSBluetoothPeripheralUsageDescription` and
    `NSBluetoothAlwaysUsageDescription` (peripheral role; foreground only — no
    background BLE mode in v1).
  - Bundle id `com.bash0c7.picoruby.VirtualPeripheral`, team `SM5792D355`,
    `CODE_SIGN_STYLE: Automatic`.
- `Rakefile`: add `ios:vperiph:{lib,gen,build,run,all}` and `ios:vperiph:device:*`,
  mirroring the REPL tasks (`ios:*` / `ios:device:*`) since both use the base
  config — `lib` stages the base `libmruby.a` into
  `examples/virtual-peripheral/Vendor/`, `gen` runs xcodegen, `build`/`run`
  build and launch for the simulator / device.

## Testing

- `examples/virtual-peripheral/test_profile.rb` — host CRuby runner (no
  BLE/Swift), in the spirit of stackchan's `test_frames.rb`. It `require`s
  `app.rb` and asserts: the serialized `profile` output for each `ACTIVE_PROFILE`
  value; `on_read`/`on_write`/`on_subscribe`/`tick` return the expected
  `value_hex` and `log_line` (e.g. NUS write of `<F:2>\n` → ACK `.` on TX +
  a readable log line; Heart Rate subscribe then tick → a bpm notify value).
- Before trusting `app.rb` on-device, **probe it against the host
  `build/host/lib/libmruby.a`** (identical reduced gem set) per the
  reduced-PicoRuby-VM discipline — verify the hand-written hex encode/decode and
  any bit ops (`>>`, `&`, `String#<<` with an Integer) are supported. Run `rake
  smoke` first to refresh presym headers.
- On-device acceptance (hardware-gated, manual): launch the app (advertises
  `PBLE-TEST`); from the Mac, point the PC `stackchan` at it
  (`BLE_NAME_PREFIX=PBLE-TEST`, `:nus` profile active) — `connect`, send `face`/
  `led`/`servo`, and confirm each frame appears in the log and the PC app
  receives the ACK. Heart-rate profile can be verified with LightBlue acting as
  central.

## Out of scope (YAGNI)

- Runtime profile switching UI (boot-time constant instead).
- Manual injection of touch/error frames or hand-typed notify values (the log is
  display-only, per "scrolling display only"). Auto-responses only.
- Background BLE advertising / state restoration.
- Any change to the picoruby-ble Darwin port or the `bash0C7/picoruby` fork.
- An app icon or in-app image (the HEIC was a configuration reference, not an
  asset).
