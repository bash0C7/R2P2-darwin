# virtual-peripheral — a BLE peripheral written in Ruby

A PicoRuby-first virtual BLE peripheral, useful as a test stub for debugging a
BLE *central*. It advertises a Heart Rate GATT service named `PBLE-TEST`, answers
reads, handles writes, and streams notifications — and every one of those
behaviours is decided in `app.rb`. The Apple CoreBluetooth framework is driven
through picoruby-ble's Darwin port; there is no Swift CoreBluetooth code in this
example.

## Where PicoRuby runs

**The whole GATT-server behaviour lives in `app.rb`.** It is a `BLE` subclass:

```ruby
class VirtualPeripheral < BLE
  def initialize
    super(:peripheral, PROFILE_DATA)   # picoruby-ble peripheral role
    ...
  end
end
```

Ruby owns when to advertise, what each read returns, how a write is answered, and
when to notify. It calls the picoruby-ble peripheral API — `advertise`,
`push_read_value`, `pop_write_value`, `notify`, `request_can_send_now_event` — and
the **Darwin port** (`ports/darwin/`, see Dependencies) turns those into
`CBPeripheralManager` operations. Swift in this example is only the VM host (a
timer that ticks the VM) and a read-only log view.

This is the point of the example: "what does this BLE device do" is Ruby, exactly
as it is on an rp2040 board. The same `app.rb` and the same picoruby-ble API run
on either target; only the port underneath differs (CoreBluetooth here, BTstack on
rp2040).

### The tick model

`app.rb` runs in a **persistent VM**, opened once at launch. There is no blocking
`BLE#start` loop; instead `VMExecutor` runs a timer (~10 Hz) that calls
`vm_call("tick")`. Each `tick`:

```
VMExecutor timer ── vm_call("tick") ─▶ VirtualPeripheral#tick
   pop_packet      drains one CoreBluetooth event (and, on Darwin, reconciles the
                   read cache / write queue on the VM thread)
   packet_callback branches on the event byte:
                     0x60 → advertise(ADV_DATA)        (radio powered on)
                     0xB5 → a central is present
                     0xB7 → push next HR value + notify (CAN_SEND_NOW)
                     0x05 → central disconnected
   pop_write_value(CCCD)    → subscribe / unsubscribe
   pop_write_value(control) → a write to the Heart Rate Control Point
```

`tick` returns nothing; it `print`s log lines, which `vm_call` returns as captured
stdout for the on-screen log.

### The reduced VM and offline blob generation

The reduced PicoRuby VM on iOS has no `Array#pack` / `String#<<` / `Integer#chr` /
`sprintf`. `BLE::GattDatabase` and `BLE::AdvertisingData` build their byte blobs
with `pack`/`<<`, so they cannot run on-device. So `tools/gen_profile.rb` runs the
**real** `GattDatabase` / `AdvertisingData` under CRuby (which has `pack`/`<<`) and
emits `PROFILE_DATA` (the BTstack ATT-DB blob), `ADV_DATA` (the AD-TLV blob), and a
256-byte `BYTE_TABLE` as frozen string literals, which are pasted into `app.rb`.
The blobs are **byte-identical to what rp2040 compiles**, so the profile and the
portability are preserved; only the build step moves offline. The live behaviour
(`app.rb` below the literals) is written for the reduced VM — `getbyte`, `+`,
`[i,1]`, and `BYTE_TABLE[n, 1]` for the int→byte conversion `chr` would otherwise do.

## Dependencies

This example needs two PicoRuby sources, neither of which is vendored here:

1. **Upstream picoruby** (`picoruby/picoruby`) — the core VM and compiler, fetched
   into `vendor/picoruby` by `rake setup` (override with `PICORUBY_REPO` /
   `PICORUBY_REF`, default `master`).

2. **The picoruby-ble Darwin/CoreBluetooth port** — lives in the `bash0C7/picoruby`
   fork on branch `picoruby-ble-darwin-port`. picoruby-ble's `ports/darwin/`
   implements the BLE peripheral (and central) port over CoreBluetooth, plus the
   Swift package (`ports/darwin/ext`, `PicoBLEDarwin`) that the C port calls and
   that the app links. Upstream picoruby-ble does not yet carry this port, so the
   example pulls the gem from the fork rather than from `vendor/picoruby`.

### Getting the fork

Clone it as a sibling of this repository (the default path the build config and
`project.yml` expect):

```sh
# from the directory that contains R2P2-iOS/
git clone --branch picoruby-ble-darwin-port \
  https://github.com/bash0C7/picoruby.git picoruby-ble-darwin-port
```

That yields `../picoruby-ble-darwin-port` next to `R2P2-iOS/`. To put it elsewhere,
set `PICORUBY_BLE_GEMDIR` to the gem directory, e.g.:

```sh
export PICORUBY_BLE_GEMDIR=/path/to/picoruby/mrbgems/picoruby-ble
```

The build reads the fork's working tree directly (it is not committed into this
repo and needs no separate fork build step), so a checkout of the branch is enough.

## Files

| File | Role |
|---|---|
| `app.rb` | the peripheral: embedded `PROFILE_DATA`/`ADV_DATA`/`BYTE_TABLE` literals + the live `tick`/`packet_callback`/read/write/subscribe/notify behaviour |
| `tools/gen_profile.rb` | offline generator (system Ruby): reuses the real `GattDatabase`/`AdvertisingData` to (re)produce the embedded literals |
| `Sources/VMExecutor.swift` | one serial thread that owns the VM (`vm_open`/`vm_call`) and the tick timer |
| `Sources/ContentView.swift` | read-only scrolling log of the printed tick output |
| `Sources/App.swift` | the `@main` app entry |
| `Sources/VirtualPeripheral-Bridging-Header.h` | exposes the C VM bridge to Swift |
| `tools/ble_write.swift` | a macOS BLE central that scans `PBLE-TEST`, connects, reads, subscribes, and writes |
| `project.yml` | xcodegen project (links+embeds `PicoBLEDarwin`, declares the Bluetooth usage string) |

## Run it

```sh
rake ios:vperiph:all          # Simulator (note: Simulator CoreBluetooth cannot advertise)
rake ios:vperiph:device:all   # connected device: build, sign, install, launch
rake ios:vperiph:write        # macOS BLE central helper that drives the peripheral
```

The Simulator boots the VM and runs `app.rb`, but its CoreBluetooth peripheral
never reaches `poweredOn`, so advertising and the radio behaviour require a real
device. `rake ios:vperiph:write` builds and runs `tools/ble_write.swift`;
`WRITE_HEX`, `TARGET_NAME`, and `APP_SERVICES` pass through the environment, e.g.
`WRITE_HEX=01 rake ios:vperiph:write` writes `0x01` to the Heart Rate Control
Point — `app.rb` logs the bytes and resets the simulated rate.

## Changing the published profile

The GATT profile is fixed in the embedded literals. To change it, edit the profile
in `tools/gen_profile.rb` (services, characteristics, advertised name), run
`ruby tools/gen_profile.rb`, and paste the regenerated `PROFILE_DATA` / `ADV_DATA` /
`BYTE_TABLE` and the handle constants into `app.rb`. Keep GATT handles ≤ 255 (the
Darwin port's event layout reads them as one byte).
