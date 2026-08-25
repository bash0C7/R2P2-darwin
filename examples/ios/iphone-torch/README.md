# iphone-torch — a Ruby-driven flashlight

日本語版: [README_jp.md](README_jp.md)

The iOS answer to "Lチカ", the blinking-LED hello world of embedded development.
Two buttons turn the iPhone's torch on and off, and the whole behaviour is Ruby:
`app.rb` calls a `Torch` class, and the `picoruby-iphone-torch` gem's darwin port
turns those calls into `AVCaptureDevice` operations. The SwiftUI layer holds no
torch logic — it boots the PicoRuby VM and forwards button taps.

This is [virtual-peripheral](../virtual-peripheral/README.md)'s design — Ruby
driving an Apple framework through a picoruby port — scaled down to the smallest
possible hardware primitive: one light, on or off. Brightness control is out of
scope.

## How it works

Each button press is one `vm_call`. The return value is whatever `app.rb`
printed, which the UI appends to its log.

```
[SwiftUI ON / OFF buttons]
  --vm_call(vm, "on"/"off", "")-->  $app (TorchApp, Ruby)  -->  Torch#on / #off
    --> src/mruby/torch.c           mruby C method
    --> TORCH_set(true/false)       include/torch.h, the port ABI
    --> ports/darwin/torch.c        the darwin port
    --> ptorch_set(1/0)             Swift @c export
    --> AVCaptureDevice.torchMode = .on / .off
```

There is no poll timer here, unlike virtual-peripheral: the torch is
fire-and-forget, so one `vm_call` per press is the whole story.

`app.rb` is not baked into the binary as bytecode. It ships as a plain-text
resource and is compiled at launch, inside the app, by PicoRuby's prism compiler
(`VMExecutor.start` → `vm_open(bootSource)`). When to light the torch, how to
flash it, what to log — all of that lives in that Ruby file. The C gem exposes
only the `Torch` primitive (`on`, `off`, `available?`); the Swift package only
pokes `AVCaptureDevice`. Neither contains any blink or counting logic.

### The blink is a Ruby loop

To make that concrete, ON runs a blink defined in Ruby: a `while` loop in
`app.rb` calls `@torch.on` and `@torch.off` `BLINK_COUNT` times with
`sleep_ms(BLINK_MS)` between, then leaves the torch lit, counting presses in
Ruby as it goes. This is the literal Lチカ — the loop is Ruby, the light is
hardware.

Change the flashing without touching C or Swift:

```sh
# edit examples/ios/iphone-torch/app.rb, e.g. set BLINK_COUNT = 7
rake ios:torch:device:build   # re-copies the app.rb resource into the .app;
                              # libmruby.a and PicoTorchDarwin are untouched
rake ios:torch:device:run     # reinstall and launch
```

The torch now flashes seven times. Only Ruby changed; the compiled C gem and the
Swift backend are byte-for-byte identical.

`sleep_ms` is a Kernel function from `mruby-task`. On iOS it blocks in real
wall-clock time through the bridge's task HAL (`../../../bridge/task_hal_ios.c`),
so the pauses between flashes are genuine rather than busy-waited.

## The gem: `picoruby-iphone-torch/`

A local mrbgem, living in this example directory rather than in
`vendor/picoruby`, and following picoruby's ports model: the interface in
`include/`, the architecture-specific implementation in `ports/<arch>/`. The
only port is `darwin`.

| Path | Role |
|---|---|
| `mrbgem.rake` | gem spec; declares no dependencies |
| `include/torch.h` | port ABI: `TORCH_set(bool)`, `TORCH_available()` |
| `src/torch.c` | VM dispatch (`#include "mruby/torch.c"`) |
| `src/mruby/torch.c` | mruby C extension defining class `Torch` (`on` / `off` / `available?`) |
| `ports/darwin/torch.c` | `TORCH_*` to the Swift `ptorch_*` externs |
| `ports/darwin/ext/` | the `PicoTorchDarwin` Swift package (`AVCaptureDevice`) |

`Torch#on`, `#off`, and `#available?` are defined in C and call the port ABI.
The darwin port delegates to `PicoTorchDarwin`, whose `@c` exports (`ptorch_set`,
`ptorch_available`) wrap `AVCaptureDevice`. That Swift package links into the app
target, resolving the `ptorch_*` symbols that `libmruby.a` deliberately leaves
undefined — the same arrangement `PicoBLEDarwin` uses in the BLE examples.

Driving the torch through `AVCaptureDevice.lockForConfiguration` starts no
capture session, so the app needs no camera permission and no privacy usage keys
in `Info.plist`.

## Build and run

Prerequisites: the full `Xcode.app`, the iOS SDK, and `xcodegen`. `rake check`
verifies them.

### Simulator

```sh
rake ios:torch:all     # lib -> gen -> build -> run
```

The Simulator has no torch. The app launches and the VM boots, but ON logs
`ON #<n>: torch unavailable (no actuation)` instead of flashing. This target
verifies that the build links and the VM runs.

### Device

Before the first device build, replace `DEVELOPMENT_TEAM: YOUR_TEAM_ID` in
`project.yml` with your own Team ID — see
[Running on a device](../../../README.md#running-on-a-device).

```sh
rake ios:torch:device:all   # needs a connected, signed iPhone
```

On a real iPhone, ON flashes the torch `BLINK_COUNT` times and leaves it lit —
the log shows `ON #<n>: blinked <BLINK_COUNT>x in Ruby, now lit` — and OFF turns
it off.

## Individual tasks

| Task | What it does |
|---|---|
| `rake ios:torch:lib` | cross-build `libmruby.a` for the Simulator SDK with the torch gem, stage under `Vendor/` |
| `rake ios:torch:gen` | generate `Torch.xcodeproj` from `project.yml` |
| `rake ios:torch:build` | build for the Simulator |
| `rake ios:torch:run` | boot a Simulator, install, launch |
| `rake ios:torch:observe` | launch repeatedly on a pinned Simulator and classify each run |
| `rake ios:torch:device:lib` | cross-build `libmruby.a` for the device SDK (iphoneos arm64) |
| `rake ios:torch:device:check` | link for a generic device without signing (no hardware needed) |
| `rake ios:torch:device:build` | build signed for a connected device |
| `rake ios:torch:device:run` | install and launch on the connected device |
| `rake ios:torch:device:all` | the full device pipeline |
