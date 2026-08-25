# stackchan — a Stack-chan BLE central in Ruby

日本語版: [README_jp.md](README_jp.md)

A PicoRuby BLE central that connects to a
[Stack-chan](https://github.com/meganetaaan/stack-chan) robot running the
`stackchan-picoruby` firmware and drives its face, LED, head servos, and servo
torque over the Nordic UART Service (NUS). All of the BLE logic lives in
`app.rb`; Swift hosts the VM and forwards button taps.

Where [virtual-peripheral](../virtual-peripheral/README.md) makes the phone a
BLE *peripheral*, this example makes it a *central* — the other half of
picoruby-ble's darwin port, exercised against real hardware.

## How it works

`app.rb` is bundled, fixed Ruby: not user-editable and not downloaded. PicoRuby
is simply the implementation language for the app's own behaviour, which keeps
it clear of App Review Guideline 2.5.2.

```
ContentView.swift  (buttons)
      │  vm_call(method, arg)
      ▼
VMExecutor.swift   (single VM thread)
      │  C bridge
      ▼
app.rb   $app = Stackchan.new
  Stackchan#connect              → RealBleLink#connect
  Stackchan#face/led/head/torque → RealBleLink#write
                                 → BLE::write_value_of_characteristic_without_response
      │
      ▼
picoruby-ble (darwin port) → PicoBLEDarwin Swift package → CoreBluetooth
```

- The central role — scan, connect, GATT discovery, NUS RX write — is driven
  through the darwin / CoreBluetooth port. There is no Swift CoreBluetooth code.
- `VMExecutor` owns the one serial VM thread and posts a periodic `tick`;
  `Stackchan#tick` pumps BLE events while connected.
- Frames written before the NUS RX handle is bound are queued and flushed once
  `connect` succeeds, so a button pressed early is not lost.

### One source file, two environments

`app.rb` runs both inside the app and under host CRuby, and decides which at
load time:

```ruby
BLE_AVAILABLE = ...   # is picoruby-ble's BLE class linked into this VM?
```

On a device or the Simulator the BLE gem is linked, so `BLE_AVAILABLE` is true
and `RealBleLink` drives the radio. Under host CRuby it is false, and a
recording `BleLink` stub captures frames for assertion instead. Every reference
to the `BLE` class is guarded behind that constant, which is why the file has no
`require_relative` and no module namespacing — it is one source, loaded whole,
in both worlds.

## Frame codec

`FrameCodec` in `app.rb` encodes every frame. Because of the split above, it
runs under host CRuby with no device, no build, and no BLE hardware:

```sh
ruby examples/ios/stackchan/test_frames.rb   # all PASS
```

One deliberate asymmetry to leave alone: the API's `"left"` and `"right"` are
Stack-chan's own perspective (its hands), and the firmware wires them reversed,
so `"left"` becomes `R` on the wire. `SIDE_TO_CHAR` matches the hardware and is
load-bearing — do not "fix" it.

## Hardware

Both ends of the BLE link are real:

- An iPhone running iOS 17 or later (any BLE-capable model).
- A Stack-chan robot flashed with the `stackchan-picoruby` firmware. It
  advertises as `StackChan-PicoRuby-<suffix>` and exposes NUS.

## Controls

Each button posts one `vm_call` onto the VM thread, and the encoded frame is
written to the NUS RX characteristic.

| Control | Frame |
|---|---|
| Face — neutral / smile / joy / surprised / sad / angry | `<F:N>`, N being the face index |
| LED — red / green / blue / yellow / white / off | `<L:1,R:r,G:g,B:b,S:B,M:s>`, both sides, solid mode |
| Head — Left | yaw left 40°, 400 ms |
| Head — Center | yaw 0°, pitch 0°, 400 ms (reset) |
| Head — Right | yaw right 40°, 400 ms |
| Head — Up | pitch up 30°, 400 ms |
| Torque — On / Off | enable or disable the servos |

## Build config

`build_config/r2p2-picoruby-ios-stackchan-{sim,device}.rb` builds the reduced
gem set plus `picoruby-ble` and the three stdlib gems its Ruby layer uses —
`mruby-pack`, `mruby-string-ext`, `mruby-sprintf`. Those three are what make
`Array#pack` and `sprintf` available to `app.rb` here but not in, say,
`iphone-torch`.

## Build and run

### Simulator

```sh
rake ios:stackchan:all      # lib -> gen -> build -> run
```

No peripheral answers on the Simulator, so the scan simply times out. This
target verifies that the build links and the VM runs.

### Device

Before the first on-device build, replace `DEVELOPMENT_TEAM: YOUR_TEAM_ID` in
`project.yml` with your own Team ID — see
[Running on a device](../../../README.md#running-on-a-device).

```sh
rake ios:stackchan:device:all
```

Or step by step:

```sh
rake ios:stackchan:device:lib     # BLE-enabled libmruby.a for the device SDK
rake ios:stackchan:gen            # generate the Xcode project
rake ios:stackchan:device:build   # build, signed
rake ios:stackchan:device:run     # install and launch, streaming the console
```

On first launch, iOS asks for Bluetooth permission — allow it.

## Constraints when running on hardware

- **Bluetooth permission.** `NSBluetoothAlwaysUsageDescription` is set in
  `project.yml`. Without it `CBCentralManager` never reaches `.poweredOn` and
  the scan is a no-op.
- **Scan timeout.** `scan(timeout_ms: 30000)` has to cover the whole
  connect → GATT discovery → idle cycle, which is several BLE round trips at
  100 ms polling. Shorten it only after measuring on your own hardware.
- **Free Personal Team app limit.** iOS allows three installed apps. Install
  error 3002 means you are at the limit; remove one with
  `xcrun devicectl device uninstall app --device <UDID> <bundle-id>`.
- **Device lock.** Launch fails with `FBSOpenApplicationServiceErrorDomain
  error 1` when the screen is locked. Unlock the phone first.
