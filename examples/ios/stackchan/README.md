# stackchan — Stack-chan BLE central in Ruby

日本語版: [README_jp.md](README_jp.md)

A PicoRuby BLE central that connects to a
[Stack-chan](https://github.com/meganetaaan/stack-chan) robot running the
`stackchan-picoruby` firmware and drives its face, LED, head servos, and torque
over the Nordic UART Service (NUS). The entire BLE logic lives in `app.rb`;
Swift only hosts the VM and forwards button taps.

## What this demonstrates

`app.rb` is bundled, fixed Ruby — not user-editable and not downloaded;
PicoRuby is simply the implementation language for the app's own behavior
(clear of App Review Guideline 2.5.2).

- `picoruby-ble` central role (scan -> connect -> GATT discovery -> NUS RX
  write) driven by the Darwin / CoreBluetooth port — no Swift CoreBluetooth
  code.
- An example-scoped build config adding the stdlib gems `picoruby-ble`'s
  mrblib needs (`mruby-pack`, `mruby-string-ext`, `mruby-sprintf`) without
  touching the minimal base config shared by other examples.
- A frame codec verifiable on host CRuby (`test_frames.rb`) with no BLE
  hardware.

## Hardware

The example needs hardware at both ends of the BLE link:

- iPhone running iOS 17+ (any BLE-capable model).
- Stack-chan robot flashed with the `stackchan-picoruby` firmware — it
  advertises as `StackChan-PicoRuby-<suffix>` and exposes NUS.

## Quick start

Device pipeline (needs a connected, signed iPhone):

```
# 1. Build BLE-enabled libmruby.a for the connected iPhone
rake ios:stackchan:device:lib

# 2. Generate and sign the Xcode project, then build
rake ios:stackchan:gen
rake ios:stackchan:device:build

# 3. Install and launch (streams console output)
rake ios:stackchan:device:run

# Or all in one step:
rake ios:stackchan:device:all
```

- First launch: iOS prompts for Bluetooth permission — allow it.
- Simulator pipeline: `rake ios:stackchan:all` (lib -> gen -> build -> run).
  No peripheral answers on the Simulator, so scan simply times out.

## Controls

Each button posts one `vm_call` onto the VM thread; the encoded frame is
written to the NUS RX characteristic.

- Face — neutral / smile / joy / surprised / sad / angry: sends `<F:N>`
  (N is the face index).
- LED — red / green / blue / yellow / white / off: sends
  `<L:1,R:r,G:g,B:b,S:B,M:s>` (both sides, solid mode).
- Head — Left: yaw left 40°, 400 ms.
- Head — Center: yaw 0°, pitch 0°, 400 ms (reset).
- Head — Right: yaw right 40°, 400 ms.
- Head — Up: pitch up 30°, 400 ms.
- Torque — On / Off: enable / disable the servos.

## Frame codec

`FrameCodec` in `app.rb` encodes every frame. The codec runs on host CRuby,
so it is testable without a device, a build, or BLE hardware:

```
ruby examples/ios/stackchan/test_frames.rb   # all PASS, no BLE hardware needed
```

- API "left"/"right" are Stack-chan's own perspective (its hands); the
  firmware wires them reversed, so "left" becomes `R` on the wire.
  `SIDE_TO_CHAR` matches the hardware and is load-bearing — do not "fix" it.

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

- `BLE_AVAILABLE` is probed at boot: on the device / Simulator (BLE linked)
  it is true and `RealBleLink` drives the radio; under host CRuby
  (`test_frames.rb`) it is false and the recording `BleLink` stub captures
  frames for assertion.
- `VMExecutor` owns the one serial VM thread and posts a periodic `tick`;
  `Stackchan#tick` pumps BLE events while connected.
- Frames written before the NUS RX handle is bound are queued and flushed
  once `connect` succeeds.

## Build config

`build_config/r2p2-picoruby-ios-stackchan-{device,sim}.rb` extends the base
VM with:

- `picoruby-ble` — Darwin port selected via `conf.ports :darwin`; its declared
  `picoruby-mbedtls` / `picoruby-cyw43` dependencies are stripped (the Darwin
  C path references neither).
- `mruby-string-ext` — `String#<<` used in `ble_utils.rb`.
- `mruby-pack` — `Array#pack` / `require 'pack'` used in `ble_utils.rb`.
- `mruby-sprintf` — `Kernel#sprintf` used in `ble_central.rb` debug
  interpolations.

The three stdlib gems are part of PicoRuby's `stdlib.gembox` (vm_mruby
branch), which every rp2040 build includes. The base iOS config omits them to
keep the REPL lean; this example adds them, example-scoped.

## Known constraints

Constraints that apply when running on a device:

- Bluetooth permission: `NSBluetoothAlwaysUsageDescription` is set in
  `project.yml`. Without it `CBCentralManager` never reaches `.poweredOn` and
  scan is a no-op.
- Scan timeout: `scan(timeout_ms: 30000)` covers the full connect -> GATT
  discovery -> TC_IDLE cycle (multiple BLE round trips at 100 ms polling).
  Reduce only after measuring on your hardware.
- Free Personal Team: iOS limits installed apps to 3. On install error
  3002, remove one with
  `xcrun devicectl device uninstall app --device <UDID> <bundleid>`.
- Device lock: launch fails with `FBSOpenApplicationServiceErrorDomain error 1`
  when the screen is locked — unlock the device first.
