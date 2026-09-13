# iphone-torch — a Ruby-driven flashlight

日本語版: [README_jp.md](README_jp.md)

The iOS answer to "Lチカ", the blinking-LED hello world of embedded development.
`app.rb` is the whole program — ten lines that read exactly like the
microcontroller version:

```ruby
require "torch"

torch = Torch.new

loop do
  torch.on
  sleep 0.5
  torch.off
  sleep 0.5
end
```

`Torch` comes from the `picoruby-iphone-torch` gem, whose darwin port turns
`on` / `off` into `AVCaptureDevice` operations. The SwiftUI layer holds no torch
logic — it shows `app.rb` on screen, hands it to the PicoRuby VM when you tap
Run, and raises a stop flag when you tap Stop.

This is [virtual-peripheral](../virtual-peripheral/README.md)'s design — Ruby
driving an Apple framework through a picoruby port — scaled down to the smallest
possible hardware primitive: one light, on or off. Brightness control is out of
scope.

## How it works

Tapping Run is the only call from Swift into the VM: `VMExecutor.start` compiles
`app.rb` in-app with PicoRuby's prism compiler and runs it (`vm_open`). The
script's `loop` never returns, so the VM thread stays inside `vm_open` for the
life of the run, flashing the torch. There is no `vm_call`, no poll timer, no
log — the torch is the output.

Stop does not touch the VM from another thread. It only sets the gem's stop
flag (`TORCH_request_stop`, `src/torch.c`); the script's next `sleep` sees it,
turns the torch off, and raises `StopIteration`, which `Kernel#loop` rescues.
`loop do ... end` returns, `app.rb` finishes, `vm_open` returns, and the VM is
closed on its own thread. Run opens a fresh VM.

```
[SwiftUI Run button]                       [Stop button] --> TORCH_request_stop()
  --vm_open(app.rb)-->  loop do torch.on / torch.off end   (Ruby, on the VM queue)
    --> src/mruby/torch.c           mruby C method
    --> TORCH_set(true/false)       include/torch.h, the port ABI
    --> ports/darwin/torch.c        the darwin port
    --> ptorch_set(1/0)             Swift @c export
    --> AVCaptureDevice.torchMode = .on / .off
```

`app.rb` is not baked into the binary as bytecode. It ships as a plain-text
resource, so the blink is changed without touching C or Swift:

```sh
# edit examples/ios/iphone-torch/app.rb, e.g. sleep 0.1
rake ios:torch:device:build   # re-copies the app.rb resource into the .app;
                              # libmruby.a and PicoTorchDarwin are untouched
rake ios:torch:device:run     # reinstall and launch
```

### `sleep` and `require "torch"` are the gem's

The torch build is a reduced gem set: `mruby-task` provides `sleep_ms` but no
`Kernel#sleep`, and `require` only resolves names registered by a gem. Both
come from `picoruby-iphone-torch/mrblib/torch.rb` (a seconds-form `sleep`
delegating to `sleep_ms`) and `spec.require_name = 'torch'` in its
`mrbgem.rake`. Nothing else in the build defines `sleep`, so there is no clash.

## The gem: `picoruby-iphone-torch/`

A local mrbgem, living in this example directory rather than in
`vendor/picoruby`, and following picoruby's ports model: the interface in
`include/`, the architecture-specific implementation in `ports/<arch>/`. The
only port is `darwin`.

| Path | Role |
|---|---|
| `mrbgem.rake` | gem spec; declares no dependencies |
| `include/torch.h` | port ABI: `TORCH_set(bool)`, `TORCH_available()` |
| `src/torch.c` | the stop flag (`TORCH_request_stop` / `_clear_stop` / `_stop_requested`) and VM dispatch (`#include "mruby/torch.c"`) |
| `src/mruby/torch.c` | mruby C extension defining class `Torch` (`on` / `off` / `available?`) |
| `mrblib/torch.rb` | `Kernel#sleep(sec)` on top of `sleep_ms`, polling `Torch.stop_requested?`; loaded at boot, so `require "torch"` just returns |
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

The Simulator has no torch. The app launches and the loop runs, but `Torch#on`
is a no-op there. This target verifies that the build links and the VM runs.

### Device

Before the first device build, replace `DEVELOPMENT_TEAM: YOUR_TEAM_ID` in
`project.yml` with your own Team ID — see
[Running on a device](../../../README.md#running-on-a-device).

```sh
rake ios:torch:device:all   # needs a connected, signed iPhone
```

On a real iPhone, tap Run: the torch blinks at 1 Hz until Stop.

## Individual tasks

| Task | What it does |
|---|---|
| `rake ios:torch:lib` | cross-build `libmruby.a` for the Simulator SDK with the torch gem, stage under `Vendor/` |
| `rake ios:torch:gen` | generate `Torch.xcodeproj` from `project.yml` |
| `rake ios:torch:build` | build for the Simulator |
| `rake ios:torch:run` | boot a Simulator, install, launch |
| `rake ios:torch:observe` | launch repeatedly on a pinned Simulator and classify each run (golden: `[Torch] VM starting`, logged just before `vm_open`) |
| `rake ios:torch:device:lib` | cross-build `libmruby.a` for the device SDK (iphoneos arm64) |
| `rake ios:torch:device:check` | link for a generic device without signing (no hardware needed) |
| `rake ios:torch:device:build` | build signed for a connected device |
| `rake ios:torch:device:run` | install and launch on the connected device |
| `rake ios:torch:device:all` | the full device pipeline |
