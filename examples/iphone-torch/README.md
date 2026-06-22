# iPhone Torch — Ruby-driven flashlight

The "L チカ" of iOS. Two buttons turn the iPhone torch (flashlight) on and off.
The whole behaviour is **Ruby**: `app.rb` calls a `Torch` class, and the
`picoruby-iphone-torch` gem's Darwin port turns those calls into
`AVCaptureDevice` torch operations. This app contains no torch logic in Swift —
the SwiftUI layer only boots the PicoRuby VM and forwards button taps.

This mirrors the design of `../virtual-peripheral` (Ruby drives an Apple
framework through a picoruby port), scaled down to the smallest possible
hardware primitive: a single on/off light. Brightness/level control is out of
scope — on and off only.

## How it works

```
[SwiftUI ON / OFF buttons]
  --vm_call(vm, "on"/"off", "")-->  $app (Ruby, TorchApp)  -->  Torch#on / #off
    --> src/mruby/torch.c   (mruby C method)
    --> TORCH_set(true/false)            include/torch.h   (port ABI)
    --> ports/darwin/torch.c             Darwin port
    --> ptorch_set(1/0)                  Swift @c export
    --> AVCaptureDevice.torchMode = .on/.off
```

There is **no poll timer** (unlike virtual-peripheral): the torch is a
fire-and-forget on/off, so each button press makes one `vm_call` and that is all.

## The behaviour is Ruby — and you can prove it

`app.rb` is **not** baked into the binary as bytecode. It ships as a plain-text
resource and is compiled **at runtime, inside the app**, by PicoRuby's prism
compiler the moment the VM boots (`VMExecutor.start` → `vm_open(bootSource)`).
Everything the app *does* — when to light the torch, how to flash it, what to log
— lives in that Ruby file. The C gem only exposes the `Torch` primitive
(`on`/`off`/`available?`); the Swift package only poke `AVCaptureDevice`. Neither
contains any "blink" or "count" logic.

To make this concrete, **ON runs a Ruby-defined blink**: it flashes the torch
`BLINK_COUNT` times (a `while` loop in `app.rb` calling `@torch.on` / `@torch.off`
with `sleep_ms` between) and then leaves it lit, while counting presses in Ruby.
This is the literal "L チカ": the *loop* is Ruby, the *light* is the hardware.

Change the flashing and see for yourself — **no C or Swift rebuild needed**:

```sh
# edit examples/iphone-torch/app.rb, e.g. set BLINK_COUNT = 7
rake ios:torch:device:build   # only re-copies the app.rb resource into the .app
#                               (libmruby.a and PicoTorchDarwin are untouched)
# reinstall + launch (see rake ios:torch:device:run)
```

The torch now flashes 7 times. You changed only Ruby; the compiled C gem and the
Swift backend are byte-for-byte the same. `sleep_ms` is a Kernel function from
`mruby-task`; on iOS it blocks in real wall-clock time via the bridge HAL
(`bridge/task_hal_ios.c`), so the pauses between flashes are genuine.

## The gem: `picoruby-iphone-torch/`

A local mrbgem (not in `vendor/picoruby`). It follows the picoruby ports model:
the interface lives in `include/`, the architecture-specific implementation in
`ports/<arch>/`. Here the only port is `darwin` (iPhone/iOS).

```
picoruby-iphone-torch/
  mrbgem.rake                 gem spec (no dependencies)
  include/torch.h             port ABI: TORCH_set(bool) / TORCH_available()
  src/torch.c                 VM dispatch (#include "mruby/torch.c")
  src/mruby/torch.c           mruby C ext: defines class Torch (on/off/available?)
  ports/darwin/torch.c        TORCH_* -> Swift ptorch_* (declares the externs)
  ports/darwin/ext/           Swift Package PicoTorchDarwin (AVCaptureDevice)
```

`Torch#on` / `#off` / `#available?` are defined in C and call the port ABI.
The Darwin port delegates to the `PicoTorchDarwin` Swift package, whose `@c`
exports (`ptorch_set`, `ptorch_available`) wrap `AVCaptureDevice`. The Swift
package links into the **app** target (resolving the `ptorch_*` symbols that are
left undefined in `libmruby.a`), exactly as `PicoBLEDarwin` does for the BLE
example.

Controlling the torch via `AVCaptureDevice.lockForConfiguration` starts no
capture session, so the app needs **no camera permission** and no privacy keys.

## Build & run

Prerequisites: full `Xcode.app`, iOS SDK, `xcodegen` (`rake check`).

### Simulator

```sh
rake ios:torch:all     # cross-build libmruby.a -> xcodegen -> build -> launch
```

The **Simulator has no torch**. The app launches and the VM boots, but ON logs
`torch unavailable (no actuation)` instead of flashing anything. This target is
for verifying the build links and the VM runs.

### Device (actual torch)

```sh
rake ios:torch:device:all   # needs a connected, signed iOS device
```

On a real iPhone, ON flashes the torch `BLINK_COUNT` times and leaves it lit
(the log shows `ON #N: blinked Nx in Ruby, now lit`); OFF turns it off.

## Individual rake tasks

| Task | What it does |
|------|--------------|
| `rake ios:torch:lib` | cross-build `libmruby.a` (Simulator) with the torch gem, stage under `Vendor/` |
| `rake ios:torch:gen` | generate `Torch.xcodeproj` from `project.yml` |
| `rake ios:torch:build` | build the app for the Simulator |
| `rake ios:torch:run` | boot a Simulator, install, launch |
| `rake ios:torch:device:lib` | cross-build `libmruby.a` for the device SDK |
| `rake ios:torch:device:build` | build signed for a connected device |
| `rake ios:torch:device:run` | install + launch on the connected device |
