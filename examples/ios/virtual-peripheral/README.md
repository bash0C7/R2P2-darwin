# virtual-peripheral — a BLE peripheral written in Ruby

日本語版: [README_jp.md](README_jp.md)

A PicoRuby-first virtual BLE peripheral, useful as a test stub for debugging a BLE central. It advertises a Heart Rate GATT service named `PBLE-TEST`, answers reads, handles writes, and streams notifications — and every one of those behaviours is decided in `app.rb`. Apple's CoreBluetooth framework is driven through picoruby-ble's Darwin port; the app contains no Swift CoreBluetooth code.

## Where PicoRuby runs

The whole GATT-server behaviour lives in `app.rb`, a `BLE` subclass:

```ruby
class VirtualPeripheral < BLE
  def initialize
    profile = build_profile
    super(:peripheral, profile)
```

- Ruby owns when to advertise, what each read returns, how a write is answered, and when to notify.
- It calls the picoruby-ble peripheral API — `advertise`, `push_read_value`, `pop_write_value`, `notify`, `request_can_send_now_event` — and the Darwin port (`ports/darwin/`, see Dependencies) turns those into `CBPeripheralManager` operations.
- Swift in this example is only the VM host (a timer that ticks the VM) and a read-only log view.
- "What does this BLE device do" is Ruby, exactly as on an rp2040 board: the same `app.rb` and the same picoruby-ble API run on either target; only the port underneath differs (CoreBluetooth here, BTstack on rp2040).

### The tick model

`app.rb` runs in a persistent VM, opened once at launch. There is no blocking `BLE#start` loop; `VMExecutor` runs a 100 ms timer (matching picoruby-ble's `POLLING_UNIT_MS`) that calls `vm_call("tick")`. Each `tick`:

- `pop_packet` drains one CoreBluetooth event (and, on Darwin, reconciles the read cache / write queue on the VM thread).
- `packet_callback` branches on the event byte:
  - `0x60` — radio powered on: advertise the AD data.
  - `0xB5` — MTU exchange complete: a central is present.
  - `0xB7` — CAN_SEND_NOW: push the next HR value and `notify`.
  - `0x05` — central disconnected.
- `pop_write_value` on the CCCD handle toggles subscribe / unsubscribe.
- `pop_write_value` on the control handle receives writes to the Heart Rate Control Point.

`tick` returns nothing; it `print`s log lines, which `vm_call` returns as captured stdout for the on-screen log.

### PicoRuby builds the profile (no pack/chr)

PicoRuby's `String`/`Array` here do not carry `Array#pack` / `String#<<` / `Integer#chr` — this is PicoRuby, not CRuby. So `app.rb` builds the BTstack ATT-DB `profile_data` and the AD-TLV `adv_data` at runtime with bit-operation equivalents:

- int to 1-byte string: a slice into a fixed 256-byte table, `BYTE_TABLE[n & 0xff, 1]` — the stand-in for `pack("C")` / `chr` (materialising a byte needs a string that already holds it, so this one literal table is irreducible).
- 16-bit little-endian: `byte(v & 0xff) + byte((v >> 8) & 0xff)`.
- concatenation: `+`.

`build_profile` / `build_adv` mirror what `BLE::GattDatabase` / `BLE::AdvertisingData` do (add_service / add_characteristic / add_descriptor, handle assignment, length prefixes), so the bytes are identical to what rp2040 compiles. No offline step, no extra gem — the profile is built in Ruby on the device, as on a board.

## Dependencies

This example needs the picoruby-ble CoreBluetooth Darwin port, which lives in the `bash0C7/picoruby` fork on branch `port-darwin`. That branch is a complete picoruby tree — upstream master plus picoruby-ble's `ports/darwin/` (the BLE peripheral/central port over CoreBluetooth) and the `PicoBLEDarwin` Swift package (`ports/darwin/ext`) that the C port calls and the app links.

- The fork and branch are the repo's default `PICORUBY_REPO` / `PICORUBY_REF`; `rake setup` fetches them into `vendor/picoruby`, so a normal checkout is enough — nothing extra to clone.
- The build config and `project.yml` read picoruby-ble from `vendor/picoruby`.
- Upstream master carries no Darwin BLE port. To fetch a different tree, override the env: `PICORUBY_REPO=https://github.com/picoruby/picoruby.git PICORUBY_REF=master rake setup`
- `PICORUBY_BLE_GEMDIR` overrides just the picoruby-ble gem directory if you keep it elsewhere.

## Files

The VM bridge and the build configs live at the repo root (`../../../bridge`, `../../../build_config`); this directory is the app, `app.rb`, and the `tools/` helper.

- `app.rb` — the peripheral: `build_profile` / `build_adv` (pack-free runtime builders) plus the live `tick` / `packet_callback` / read / write / subscribe / notify behaviour.
- `Sources/VMExecutor.swift` — one serial thread that owns the VM (`vm_open` / `vm_call`) and the tick timer.
- `Sources/ContentView.swift` — read-only scrolling log of the printed tick output.
- `Sources/App.swift` — the `@main` app entry.
- `Sources/VirtualPeripheral-Bridging-Header.h` — exposes the C VM bridge to Swift.
- `tools/ble_write.swift` — a macOS BLE central that scans `PBLE-TEST`, connects, reads, subscribes, and writes.
- `project.yml` — xcodegen project; links and embeds `PicoBLEDarwin` and declares the Bluetooth usage string.

## Run it

The app runs on the Simulator and on a connected device; a third task runs the macOS central helper.

```sh
rake ios:vperiph:all          # Simulator pipeline: lib -> gen -> build -> run
rake ios:vperiph:device:all   # connected device: build, sign, install, launch
rake ios:vperiph:write        # macOS BLE central helper that drives the peripheral
```

- The Simulator boots the VM and runs `app.rb`, but Simulator CoreBluetooth never reaches `poweredOn`; advertising and the radio behaviour require a real device.
- `rake ios:vperiph:write` builds and runs `tools/ble_write.swift`. `WRITE_HEX`, `TARGET_NAME`, and `APP_SERVICES` pass through the environment: `WRITE_HEX=01 rake ios:vperiph:write` writes `0x01` to the Heart Rate Control Point, and `app.rb` logs the bytes and resets the simulated rate.

## Changing the published profile

Edit `build_profile` / `build_adv` in `app.rb` directly (services, characteristics, advertised name) and the `HR_*` handle constants.

- Handles are assigned in build order: service=1, 0x2A37 decl=2, value=3, CCCD=4, 0x2A39 decl=5, value=6.
- Keep handles at most 255 — the Darwin port's event layout reads them as one byte.
