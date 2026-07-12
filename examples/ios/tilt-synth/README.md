# Tilt Synth — Ruby-driven Device Motion FM synthesizer

日本語版: [README_jp.md](README_jp.md)

A technical PoC: tilt the iPhone and Ruby (`app.rb`) reads the Device Motion
attitude (pitch/roll) through the `picoruby-iphone-motion` gem's Darwin port,
quantizes pitch to a 2-octave C major pentatonic scale, maps roll to FM depth,
and drives an `AVAudioEngine` sine+FM oscillator through the
`picoruby-iphone-synth` gem's Darwin port. Neither gem's Swift backend
contains any music-mapping logic; the scale, the ranges, and the tick loop are
all `app.rb`. The design mirrors picoruby-ot's `otmeiwa.rb` (sensor read) +
`web/` (sensor-to-music mapping) pair, collapsed into a single native iOS app:
no serial link, no browser, no external sensor board.

## How it works

The persistent PicoRuby VM boots `app.rb` (`$app = TiltSynthApp.new`, which
starts the Synth), then `VMExecutor` calls `tick` at 20 Hz on the single VM
thread.

```
[CMDeviceMotion attitude]
  --> ports/darwin/motion.c   (Swift @c: pmotion_available/pmotion_pitch/pmotion_roll)
  --> include/motion.h        (port ABI)
  --> src/mruby/motion.c      (Motion class)

app.rb tick:
  note  = quantize(pitch)                          # -30..+30 deg -> nearest step in PENTATONIC_SCALE
  depth = clamp((roll + 45.0) / 90.0, 0.0, 1.0)    # -45..+45 deg -> FM depth
  @synth.note = note
  @synth.fm_depth = depth

[Synth#note= / #fm_depth= / #start / #stop]
  --> ports/darwin/synth.c    (Swift @c: psynth_start/psynth_stop/psynth_set_note/psynth_set_fm_depth)
  --> Swift PicoSynthDarwin: AVAudioEngine + AVAudioSourceNode (sine + FM)
  --> speaker
```

- There is no button: the tick timer (and therefore the synth) runs
  continuously from the moment the VM boots, the same always-on model as
  `virtual-peripheral`'s poll tick.
- The SwiftUI view holds no music logic; it displays the log lines `app.rb`
  prints and parses pitch/roll out of the latest line for two gauges.

## The gems

Both are local mrbgems (not in `vendor/picoruby`), following the same
`include/` + `src/` + `ports/darwin/` + Swift-package structure as
`picoruby-iphone-torch`. Neither declares gem dependencies; the `pmotion_*` /
`psynth_*` Swift symbols resolve at app link time.

- `picoruby-iphone-motion/` — CMDeviceMotion attitude.pitch/roll ->
  `Motion#pitch` / `#roll` / `#available?`
- `picoruby-iphone-synth/` — AVAudioEngine sine+FM oscillator ->
  `Synth#note=` / `#fm_depth=` / `#start` / `#stop`

## Testing the mapping logic without Xcode

The quantize/clamp math runs under host CRuby, with no device, no build, and
no Xcode.

```sh
ruby examples/ios/tilt-synth/test_mapping.rb
```

- Stubs `Motion`/`Synth` (normally provided by the gems) and asserts the
  quantize/clamp math, mirroring `examples/ios/stackchan/test_frames.rb`.

## Build and run

Prerequisites: full `Xcode.app`, iOS SDK, `xcodegen` (verify with `rake check`).

### Simulator

```sh
rake ios:tiltsynth:all     # cross-build libmruby.a -> xcodegen -> build -> launch
```

- The Simulator has no Device Motion. The app boots and the VM runs, but
  `Motion#available?` is `false`, so `initialize` queues the one-shot status
  line "ready: no device motion (Simulator?) -- tick will no-op". It surfaces
  on the first tick: `flush_log` runs inside `tick`, and `VMExecutor` captures
  stdout from `vm_call` only, not from `vm_open`. The app stays silent.
- This target verifies that the build links and the VM runs, the same pattern
  as `iphone-torch`'s Simulator target, which has no torch.

### Device (actual tilt + sound)

```sh
rake ios:tiltsynth:device:all   # needs a connected, signed iOS device
```

- On a real iPhone, tilting the phone up/down changes the pitch in discrete
  pentatonic steps, and rolling it left/right changes the FM depth (timbre).
- Confirming this audibly and visually is a manual step; there is no automated
  on-device test in this repo.

## Individual rake tasks

Each stage of the pipeline is also a standalone task.

- `rake ios:tiltsynth:lib` — cross-build `libmruby.a` (Simulator) with both
  gems, stage under `Vendor/`
- `rake ios:tiltsynth:gen` — generate `TiltSynth.xcodeproj` from `project.yml`
- `rake ios:tiltsynth:build` — build the app for the Simulator
- `rake ios:tiltsynth:run` — boot a Simulator, install, launch
- `rake ios:tiltsynth:device:lib` — cross-build `libmruby.a` (iphoneos arm64)
  for the device SDK
- `rake ios:tiltsynth:device:build` — build signed for a connected device
- `rake ios:tiltsynth:device:run` — install + launch on the connected device

## Scope (YAGNI)

The PoC deliberately leaves these out of scope:

- No GPS altitude / barometer.
- No continuous portamento (discrete scale quantization only).
- No scale-switching UI, no microphone input, no recording.
- No rp2040/esp32 port.
