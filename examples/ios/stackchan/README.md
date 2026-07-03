# stackchan — Stack-chan BLE central in Ruby

A PicoRuby-first BLE *central* that connects to a
[Stack-chan](https://github.com/meganetaaan/stack-chan) robot running the
`stackchan-picoruby` firmware and drives its face, LED, servo, and torque over
Nordic UART Service (NUS). The entire BLE logic lives in `app.rb`; Swift hosts
the VM and forwards button taps.

## What this demonstrates

- `picoruby-ble` central role (scan → connect → GATT discovery → NUS RX write)
  driven by the **Darwin / CoreBluetooth port** — no Swift CoreBluetooth code.
- Example-scoped build config adding stdlib gems (`mruby-pack`, `mruby-string-ext`,
  `mruby-sprintf`) that `picoruby-ble`'s mrblib needs, without touching the
  minimal base config shared by other examples.
- Frame codec tested on host CRuby (`test_frames.rb`) before any BLE wiring.

## Hardware

- iPhone running iOS 17+ (any model with BLE)
- Stack-chan robot flashed with `stackchan-picoruby` firmware — it advertises as
  `StackChan-PicoRuby-<suffix>` and exposes NUS (Nordic UART Service).

## Quick start

```
# 1. Build BLE-enabled libmruby.a for the connected iPhone
rake ios:stackchan:device:lib

# 2. Generate and sign the Xcode project
rake ios:stackchan:gen
rake ios:stackchan:device:build

# 3. Install and launch (streams console output)
rake ios:stackchan:device:run

# Or all in one step:
rake ios:stackchan:device:all
```

First launch: iOS will prompt for Bluetooth permission — allow it.

## Controls

| Group  | Button  | Command sent                          |
|--------|---------|---------------------------------------|
| Face   | neutral / smile / joy / surprised / sad / angry | `<F:N>` |
| LED    | red / green / blue / yellow / white / off | `<L:1,R:r,G:g,B:b,S:B,M:s>` |
| Head   | Left    | yaw left 40°, 400 ms                  |
| Head   | Center  | yaw 0°, pitch 0°, 400 ms (reset)      |
| Head   | Right   | yaw right 40°, 400 ms                 |
| Head   | Up      | pitch up 30°, 400 ms                  |
| Torque | On / Off | enable / disable servos              |

## Frame codec

`FrameCodec` in `app.rb` encodes all frames. The codec is tested independently
of BLE on host CRuby:

```
ruby examples/ios/stackchan/test_frames.rb   # all PASS, no BLE hardware needed
```

## Architecture

```
ContentView.swift  (buttons)
      │  vm_call(method, arg)
      ▼
VMExecutor.swift   (single VM thread)
      │  C bridge
      ▼
app.rb  $app = Stackchan.new
  Stackchan#connect   → RealBleLink#connect
  Stackchan#face/led/head/torque → RealBleLink#write → BLE::write_value_of_characteristic_without_response
      │
      ▼
picoruby-ble (Darwin port)  →  PicoBLEDarwin Swift package  →  CoreBluetooth
```

`BLE_AVAILABLE` is probed at boot: on-device (BLE linked) it is `true` and
`RealBleLink` is used; under host CRuby (`test_frames.rb`) it is `false` and the
recording `BleLink` stub captures frames for assertion.

## Build config

`build_config/r2p2-picoruby-ios-stackchan-{device,sim}.rb` extends the base VM
with:

- `picoruby-ble` (Darwin port via `conf.ports :darwin`)
- `mruby-string-ext` — `String#<<` used in `ble_utils.rb`
- `mruby-pack` — `Array#pack` / `require 'pack'` used in `ble_utils.rb`
- `mruby-sprintf` — `Kernel#sprintf` used in `ble_central.rb` debug interpolations

These three are part of PicoRuby's standard `stdlib.gembox` (vm_mruby branch)
that every rp2040 build includes. The base iOS config omits them to keep the REPL
lean; the stackchan example adds them here, example-scoped.

## Known constraints

- **Bluetooth permission**: `NSBluetoothAlwaysUsageDescription` is set in
  `project.yml`. Without it `CBCentralManager` never reaches `.poweredOn` and
  scan is a no-op.
- **Scan timeout**: `scan(timeout_ms: 30_000)` covers the full connect → GATT
  discovery → TC_IDLE cycle (multiple BLE round trips at 100 ms polling). Reduce
  only after measuring on your hardware.
- **Free Personal Team**: iOS limits to 3 installed apps. Remove one with
  `xcrun devicectl device uninstall app --device <UDID> <bundleid>` if you hit
  install error 3002.
- **Device lock**: launch fails with `FBSOpenApplicationServiceErrorDomain error 1`
  if the screen is locked — unlock before tapping Connect.
