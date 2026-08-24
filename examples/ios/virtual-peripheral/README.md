# virtual-peripheral — a BLE peripheral written in Ruby

日本語版: [README_jp.md](README_jp.md)

A PicoRuby-first virtual BLE peripheral, useful as a test stub for debugging a BLE central. It advertises a Heart Rate GATT service named `PBLE-TEST`, answers reads, handles writes, and streams notifications — and every one of those behaviours is decided in `app.rb`. Apple's CoreBluetooth framework is driven through picoruby-ble's Darwin port; the app contains no Swift CoreBluetooth code.

## How it works

The whole GATT-server behaviour lives in `app.rb`, a `BLE` subclass:

```ruby
class VirtualPeripheral < BLE
  def initialize
    db = BLE::GattDatabase.new do |gatt|
      gatt.add_service(GATT_PRIMARY_SERVICE_UUID, HR_SERVICE) do |service|
        ...
      end
    end
    super(:peripheral, db.profile_data)
```

- Ruby owns when to advertise, what each read returns, how a write is answered, and when to notify.
- It calls the picoruby-ble peripheral API — `start`, `advertise`, `push_read_value`, `pop_write_value`, `notify`, `request_can_send_now_event` — and the Darwin port (`ports/darwin/`, see Dependencies) turns those into `CBPeripheralManager` operations.
- Swift in this example is only the VM host (a timer that ticks the VM) and a read-only log view.
- "What does this BLE device do" is Ruby, exactly as on an rp2040 board: the same `app.rb` and the same picoruby-ble API run on either target; only the port underneath differs (CoreBluetooth here, BTstack on rp2040).

### The event-loop model

`app.rb` runs in a persistent VM, opened once at launch. `BLE#start(timeout_ms)` is picoruby-ble's canonical event loop: it powers the radio on, blocks on the internal event queue (legal because the VM bridge dispatches every `vm_call` inside a task), dispatches events, and powers the radio off when the timeout expires. `VMExecutor` calls `vm_call("tick")` continuously; each `tick` is one bounded `start(WINDOW_MS)` window, so the peripheral sits inside the event loop for nearly all wall-clock time. Inside a window:

- `packet_callback` receives the port's events and branches on the first byte:
  - `0x60` — services registered, radio working: advertise the AD data.
  - `0xB5` — MTU exchange complete: a central is present.
  - `0xB7` — CAN_SEND_NOW: push the next HR value and `notify`.
  - `0x05` — central disconnected.
- `heartbeat_callback` (~1 Hz) does the steady-state work: `pop_write_value` on the CCCD handle toggles subscribe / unsubscribe, `pop_write_value` on the control handle receives Heart Rate Control Point writes, and while subscribed it paces `request_can_send_now_event` — one notification per heartbeat.

Closing a window powers the radio off, which stops CoreBluetooth advertising; the next window re-arms it on the way in (`tick`), so advertising restarts at most once per window. `tick` returns nothing; it `print`s log lines, which `vm_call` returns as captured stdout for the on-screen log.

### The profile is built with the canonical builders

`BLE::GattDatabase` builds the BTstack ATT-DB `profile_data` and `BLE::AdvertisingData` builds the AD-TLV `adv_data` — the same builders rp2040 uses, running on the device at boot. They need `Array#pack` / `String#setbyte` / friends, which the vperiph build configs carry (`mruby-pack`, `mruby-string-ext`, `mruby-sprintf`). ATT handles are read back from `db.handle_table` instead of being hardcoded:

```ruby
hr = db.handle_table[HR_SERVICE][HR_MEASUREMENT]
@meas_handle = hr[:value_handle]
@cccd_handle = hr[CLIENT_CHARACTERISTIC_CONFIGURATION]
```

## Changing the published profile

Edit the `BLE::GattDatabase.new` block and the `BLE::AdvertisingData.build` block in `app.rb` directly (services, characteristics, advertised name). Handles follow build order automatically via `handle_table`.

- Keep handles at most 255 — the Darwin port's event layout reads them as one byte.

## Files

The VM bridge and the build configs live at the repo root (`../../../bridge`, `../../../build_config`); this directory is the app, `app.rb`, and the `tools/` helper.

- `app.rb` — the peripheral: the `GattDatabase` / `AdvertisingData` profile, the per-tick `start` window, and the live `packet_callback` / `heartbeat_callback` / read / write / subscribe / notify behaviour.
- `Sources/VMExecutor.swift` — one serial thread that owns the VM (`vm_open` / `vm_call`) and the tick timer.
- `Sources/ContentView.swift` — read-only scrolling log of the printed tick output.
- `Sources/App.swift` — the `@main` app entry.
- `Sources/VirtualPeripheral-Bridging-Header.h` — exposes the C VM bridge to Swift.
- `tools/ble_write.swift` — a macOS BLE central that scans `PBLE-TEST`, connects, reads, subscribes, and writes.
- `project.yml` — xcodegen project; links and embeds `PicoBLEDarwin` and declares the Bluetooth usage string.

## Dependencies

This example needs the picoruby-ble CoreBluetooth Darwin port, which lives in the `bash0C7/picoruby` fork on branch `port-darwin`. That branch is a complete picoruby tree — upstream master plus picoruby-ble's `ports/darwin/` (the BLE peripheral/central port over CoreBluetooth) and the `PicoBLEDarwin` Swift package (`ports/darwin/ext`) that the C port calls and the app links.

- The fork and branch are the repo's default `PICORUBY_REPO` / `PICORUBY_REF`; `rake setup` fetches them into `vendor/picoruby`, so a normal checkout is enough — nothing extra to clone.
- The build config and `project.yml` read picoruby-ble from `vendor/picoruby`.
- Upstream master carries no Darwin BLE port. To fetch a different tree, override the env: `PICORUBY_REPO=https://github.com/picoruby/picoruby.git PICORUBY_REF=master rake setup`
- `PICORUBY_BLE_GEMDIR` overrides just the picoruby-ble gem directory if you keep it elsewhere.

## Build & run

The app runs on the Simulator and on a connected device; a third task runs the macOS central helper.

### Simulator

```sh
rake ios:vperiph:all          # Simulator pipeline: lib -> gen -> build -> run
```

- The Simulator boots the VM and runs `app.rb`, but Simulator CoreBluetooth never reaches `poweredOn`; advertising and the radio behaviour require a real device.

### Device

`project.yml` carries `DEVELOPMENT_TEAM` for device signing — replace it with your own Apple Team ID if you are not this repo's owner; see [On-device builds](../../../README.md#on-device-builds) for details.

```sh
rake ios:vperiph:device:all   # connected device: build, sign, install, launch
```

`rake ios:vperiph:write` builds and runs `tools/ble_write.swift`, a macOS BLE central that drives the peripheral:

```sh
rake ios:vperiph:write        # macOS BLE central helper that drives the peripheral
```

`WRITE_HEX`, `TARGET_NAME`, and `APP_SERVICES` pass through the environment: `WRITE_HEX=01 rake ios:vperiph:write` writes `0x01` to the Heart Rate Control Point, and `app.rb` logs the bytes and resets the simulated rate.
