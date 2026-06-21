# virtual-peripheral — a BLE peripheral written in Ruby

A PicoRuby-first virtual BLE peripheral, useful as a test stub for debugging a
BLE *central*. It advertises a GATT profile (a Heart Rate service named
`PBLE-TEST`) and streams every central event into a read-only scrolling log.

## Where PicoRuby runs

**The whole device behavior lives in `app.rb`** — which services and
characteristics exist, what a read returns, how a write is answered, what gets
notified. Swift holds no device logic. This is the point of the example: the
"what does this BLE device do" layer is Ruby; the Swift layer is only the radio,
the bridge, and the log view.

`app.rb` runs in a **persistent VM**: opened once at launch, then called per
event. The dispatcher is the Ruby global `$app`, an instance of
`VirtualPeripheral`.

```
PeripheralManager (CBPeripheralManager)        app.rb ($app), persistent VM
  launch ───────────── vm_open(app.rb) ───────▶ defines the class, sets $app
  power on ─────────── vm_call("profile") ─────▶ profile   → "NAME/SERVICE/CHAR" lines
        build the GATT tree + advertise
  central reads ────── vm_call("on_read", uuid) → on_read   → "<hex>|<log>"
  central writes ───── vm_call("on_write", …) ──▶ on_write  → "<uuid>:<hex>|<log>"
  central subscribes ─ vm_call("on_subscribe") ─▶ on_subscribe
  1 Hz timer ───────── vm_call("tick") ─────────▶ tick      → "<uuid>:<hex>|<log>" or nothing
```

### The bridge seam (worth understanding before editing `app.rb`)

- `vm_call` returns the method's **captured stdout, not its return value**. So
  every handler `print`s its result. Swift parses the printed string.
- The printed protocol is `"<value>|<log>"`: the part before `|` is the bytes to
  return/notify (a characteristic UUID plus `:` plus hex, where relevant), the
  part after `|` is a human-readable log line.
- Characteristic values cross the bridge as **lowercase hex ASCII**, because the
  C-string return cannot carry NUL bytes.
- The reduced PicoRuby VM has no `String#ord` / `Integer#chr` / `Array#pack` /
  `sprintf`, so `app.rb`'s `Hex` module builds and parses hex by hand through a
  printable-ASCII table. Probe new Ruby against the host build before relying on
  it (`rake smoke`).

### Why the peripheral is Swift, not the picoruby-ble port

picoruby-ble's Darwin port is a BLE *central*. A *peripheral* needs
`CBPeripheralManager`, so it is written in pure Swift here in the example's
`Sources/`. It stays in this repo rather than the picoruby fork — the fork owns
the central port, the example owns its peripheral.

## Files

| File | Role |
|---|---|
| `app.rb` | the brain: GATT profiles (data) + `profile`/`on_read`/`on_write`/`on_subscribe`/`tick` |
| `Sources/PeripheralManager.swift` | `CBPeripheralManager`; builds GATT from `profile`, advertises, routes events to the VM |
| `Sources/VMExecutor.swift` | one serial thread that owns the VM (`vm_open`/`vm_call`) |
| `Sources/ContentView.swift` | read-only scrolling log of every event |
| `Sources/App.swift` | the `@main` app entry |
| `tools/ble_write.swift` | a macOS BLE central that scans, connects, reads, subscribes, and writes |
| `test_profile.rb` | host-side test of `app.rb`'s output (run with system Ruby) |
| `project.yml` | xcodegen project (declares the Bluetooth usage strings) |

## Run it

```
rake ios:vperiph:all          # Simulator (advertising needs a real radio)
rake ios:vperiph:device:all   # connected device: build, sign, install, launch
rake ios:vperiph:write        # macOS BLE central helper that drives the peripheral
```

`rake ios:vperiph:write` builds and runs `tools/ble_write.swift`. `WRITE_HEX`,
`TARGET_NAME`, and `APP_SERVICES` pass through the environment, e.g.
`WRITE_HEX=02 rake ios:vperiph:write` writes `0x02` to the Heart Rate Control
Point and `app.rb`'s `on_write` logs it.

## Switching the published profile

`app.rb` carries two profiles as data — a Heart Rate profile and a Nordic UART
(NUS) profile — and publishes whichever `ACTIVE_PROFILE` names. Change that
constant and rebuild; there is no runtime switch.
