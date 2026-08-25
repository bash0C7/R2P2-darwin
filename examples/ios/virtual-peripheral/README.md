# virtual-peripheral — a BLE peripheral written in Ruby

日本語版: [README_jp.md](README_jp.md)

An iPhone acting as a BLE GATT peripheral, with every decision made in Ruby. It
advertises a Heart Rate service under the name `PBLE-TEST`, answers reads,
handles writes, and streams notifications. That makes it a useful test stub when
you are debugging a BLE central and would rather not depend on real hardware
behaving.

Apple's CoreBluetooth is driven through picoruby-ble's darwin port. The app
contains no Swift CoreBluetooth code at all.

## How it works

The whole GATT-server behaviour lives in `app.rb`, as a `BLE` subclass:

```ruby
require "ble"

class VirtualPeripheral < BLE
  def initialize
    db = BLE::GattDatabase.new do |gatt|
      gatt.add_service(GATT_PRIMARY_SERVICE_UUID, HR_SERVICE) do |service|
        ...
      end
    end
    super(:peripheral, db.profile_data)
```

- Ruby owns when to advertise, what each read returns, how a write is answered,
  and when to notify.
- It calls picoruby-ble's peripheral API — `start`, `advertise`,
  `push_read_value`, `pop_write_value`, `notify`,
  `request_can_send_now_event` — and the darwin port turns those into
  `CBPeripheralManager` operations.
- Swift here is only the VM host (a timer that ticks the VM) and a read-only log
  view.
- "What does this BLE device do" is a Ruby question, exactly as it is on an
  rp2040 board: the same `app.rb` against the same picoruby-ble API runs on
  either target. Only the port underneath differs — CoreBluetooth here, BTstack
  on rp2040.

### The event loop

`app.rb` runs in a persistent VM opened once at launch. `BLE#start(timeout_ms)`
is picoruby-ble's canonical event loop: it powers the radio on, blocks on the
internal event queue, dispatches events, and powers the radio off when the
timeout expires. Blocking is legal because the bridge dispatches every `vm_call`
inside an mruby task, so the pop parks on the scheduler rather than raising on
the root context.

`VMExecutor` calls `vm_call("tick")` continuously, and each `tick` is one
bounded `start(WINDOW_MS)` window — 1000 ms. The peripheral is therefore inside
the event loop for nearly all wall-clock time. Within a window:

- `packet_callback` receives the port's events and branches on the first byte:

  | Byte | Meaning | What Ruby does |
  |---|---|---|
  | `0x60` | services registered, radio working | advertise the AD data |
  | `0xB5` | MTU exchange complete | a central is present |
  | `0xB7` | CAN_SEND_NOW | push the next HR value and `notify` |
  | `0x05` | disconnection | drop back to advertising state |

- `heartbeat_callback`, at roughly 1 Hz, does the steady-state work:
  `pop_write_value` on the CCCD handle toggles subscribe and unsubscribe,
  `pop_write_value` on the control handle receives Heart Rate Control Point
  writes, and while subscribed it paces `request_can_send_now_event` — one
  notification per heartbeat.

Closing a window powers the radio off, which stops CoreBluetooth advertising;
the next `tick` re-arms it on the way in, so advertising restarts at most once
per window. `tick` returns nothing — it `print`s log lines, which `vm_call`
hands back as captured stdout for the on-screen log.

### The profile is built at boot, on the device

`BLE::GattDatabase` builds the BTstack ATT-DB `profile_data` and
`BLE::AdvertisingData` builds the AD-TLV `adv_data` — the same builders rp2040
uses, running on the phone at boot rather than baked in ahead of time.

They need `Array#pack`, `String#setbyte`, and friends, so this example's build
configs carry `mruby-pack`, `mruby-string-ext`, and `mruby-sprintf` on top of
the reduced gem set. ATT handles are read back from `db.handle_table` instead of
being hardcoded:

```ruby
hr = db.handle_table[HR_SERVICE][HR_MEASUREMENT]
@meas_handle = hr[:value_handle]
@cccd_handle = hr[CLIENT_CHARACTERISTIC_CONFIGURATION]
```

## Changing the published profile

Edit the `BLE::GattDatabase.new` block and the `BLE::AdvertisingData.build`
block in `app.rb` — services, characteristics, the advertised name. Handles
follow build order automatically through `handle_table`, so nothing else needs
updating.

One limit: keep handles at or below 255. The darwin port's event layout reads
them as a single byte.

## Files

The VM bridge and the build configs live at the repository root
(`../../../bridge`, `../../../build_config`); this directory holds the app,
`app.rb`, and one helper tool.

- `app.rb` — the peripheral: the `GattDatabase` and `AdvertisingData` profile,
  the per-tick `start` window, and the live `packet_callback` /
  `heartbeat_callback` / read / write / subscribe / notify behaviour.
- `Sources/VMExecutor.swift` — one serial thread owning the VM (`vm_open`,
  `vm_call`) and the tick timer.
- `Sources/ContentView.swift` — a read-only scrolling log of the printed tick
  output.
- `Sources/App.swift` — the `@main` entry point.
- `Sources/VirtualPeripheral-Bridging-Header.h` — exposes the C VM bridge to
  Swift.
- `tools/ble_write.swift` — a macOS BLE central that scans for `PBLE-TEST`,
  connects, reads, subscribes, and writes.
- `project.yml` — the xcodegen project: links and embeds the `PicoBLEDarwin`
  Swift package and declares the Bluetooth usage string.

## Dependencies

This example needs picoruby-ble's CoreBluetooth darwin port: `ports/darwin/`
(the BLE peripheral and central port) plus the `PicoBLEDarwin` Swift package
under `ports/darwin/ext`, which the C port calls and the app links.

The repository's default `PICORUBY_REPO` / `PICORUBY_REF` already point at a
tree carrying them, so `rake setup` on a plain checkout is enough — there is
nothing extra to clone. See
[Vendor source](../../../README.md#vendor-source). Upstream
`picoruby/picoruby` master carries no darwin BLE port.

`PICORUBY_BLE_GEMDIR` overrides just the picoruby-ble gem directory, for working
against a separate checkout of that gem without re-pointing the whole vendor
tree.

## Build and run

### Simulator

```sh
rake ios:vperiph:all          # lib -> gen -> build -> run
```

The Simulator boots the VM and runs `app.rb`, but Simulator CoreBluetooth never
reaches `poweredOn`. Advertising and the radio behaviour need a real device;
this target verifies that the build links and the VM runs.

### Device

Before the first on-device build, replace `DEVELOPMENT_TEAM: YOUR_TEAM_ID` in
`project.yml` with your own Team ID — see
[Running on a device](../../../README.md#running-on-a-device). iOS prompts once
for Bluetooth permission on first launch.

```sh
rake ios:vperiph:device:all   # lib -> gen -> build (signed) -> install -> launch
```

### Driving it from the Mac

`rake ios:vperiph:write` compiles and runs `tools/ble_write.swift`, a macOS BLE
central that scans for the peripheral, connects, reads, subscribes, and writes.

```sh
rake ios:vperiph:write
WRITE_HEX=01 rake ios:vperiph:write   # write 0x01 to the Heart Rate Control Point
```

`WRITE_HEX`, `TARGET_NAME`, and `APP_SERVICES` pass through the environment.
With `WRITE_HEX=01`, `app.rb` logs the received bytes and resets the simulated
rate — the round-trip from Mac to Ruby on the phone and back into the log.
