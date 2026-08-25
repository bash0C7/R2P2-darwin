# tilt-synth — a Device Motion FM synthesizer driven from Ruby

日本語版: [README_jp.md](README_jp.md)

Tilt the iPhone and it plays. `app.rb` reads the Device Motion attitude —
pitch and roll — through the `picoruby-iphone-motion` gem's darwin port,
quantizes pitch onto a two-octave C major pentatonic scale, maps roll to FM
depth, and drives an `AVAudioEngine` sine-plus-FM oscillator through the
`picoruby-iphone-synth` gem's darwin port.

Neither gem's Swift backend contains any musical logic. The scale, the ranges,
and the tick loop are all Ruby.

## How it works

The persistent VM boots `app.rb`, which assigns `$app = TiltSynthApp.new` and
starts the synth. `VMExecutor` then calls `tick` every 50 ms — 20 Hz — on the
single VM thread.

```
[CMDeviceMotion attitude]
  --> ports/darwin/motion.c   Swift @c: pmotion_available / pmotion_pitch / pmotion_roll
  --> include/motion.h        port ABI
  --> src/mruby/motion.c      the Motion class

app.rb#tick:
  note  = quantize(pitch)                          # -30..+30 deg -> nearest pentatonic step
  depth = clamp((roll + 45.0) / 90.0, 0.0, 1.0)    # -45..+45 deg -> FM depth
  @synth.note = note
  @synth.fm_depth = depth

[Synth#note= / #fm_depth= / #start / #stop]
  --> ports/darwin/synth.c    Swift @c: psynth_start / psynth_stop /
                              psynth_set_note / psynth_set_fm_depth
  --> PicoSynthDarwin (Swift): AVAudioEngine + AVAudioSourceNode (sine + FM)
  --> speaker
```

- There is no button. The tick timer, and therefore the synth, runs continuously
  from the moment the VM boots — the same always-on shape as
  [virtual-peripheral](../virtual-peripheral/README.md)'s poll tick.
- The SwiftUI view holds no music logic. It shows the log lines `app.rb` prints
  and parses pitch and roll out of the latest line to drive two gauges.

## The gems

Both are local mrbgems, living in this example directory rather than in
`vendor/picoruby`, and following the same `include/` + `src/` + `ports/darwin/`
+ Swift-package structure as
[picoruby-iphone-torch](../iphone-torch/README.md). Neither declares gem
dependencies; the `pmotion_*` and `psynth_*` Swift symbols are left undefined in
`libmruby.a` and resolve when the app links.

- `picoruby-iphone-motion/` — `CMDeviceMotion` attitude, exposed as
  `Motion#pitch`, `#roll`, `#available?`.
- `picoruby-iphone-synth/` — an `AVAudioEngine` sine-plus-FM oscillator, exposed
  as `Synth#note=`, `#fm_depth=`, `#start`, `#stop`.

## Testing the mapping without Xcode

The quantize and clamp arithmetic is ordinary Ruby, so it runs under host CRuby
with no device, no build, and no Xcode:

```sh
ruby examples/ios/tilt-synth/test_mapping.rb
```

The script stubs `Motion` and `Synth` — normally supplied by the gems — and
asserts the mapping, mirroring
[stackchan's `test_frames.rb`](../stackchan/README.md#frame-codec).

## Build and run

Prerequisites: the full `Xcode.app`, the iOS SDK, and `xcodegen`. `rake check`
verifies them.

### Simulator

```sh
rake ios:tiltsynth:all     # lib -> gen -> build -> run
```

The Simulator has no Device Motion. The app boots and the VM runs, but
`Motion#available?` is false, so `initialize` queues the one-shot status line
`ready: no device motion (Simulator?) -- tick will no-op`. That line surfaces on
the first tick rather than at boot, because `flush_log` runs inside `tick` and
`VMExecutor` captures stdout from `vm_call` only, not from `vm_open`. After
that the app stays silent. This target verifies that the build links and the VM
runs — the same role the Simulator plays for `iphone-torch`, which has no torch.

### Device

Before the first device build, replace `DEVELOPMENT_TEAM: YOUR_TEAM_ID` in
`project.yml` with your own Team ID — see
[Running on a device](../../../README.md#running-on-a-device).

```sh
rake ios:tiltsynth:device:all   # needs a connected, signed iPhone
```

Tilting the phone up and down steps the pitch through the pentatonic scale;
rolling it left and right changes the FM depth, and so the timbre. Confirming
that audibly is a manual step — there is no automated on-device audio test here.

## Individual tasks

| Task | What it does |
|---|---|
| `rake ios:tiltsynth:lib` | cross-build `libmruby.a` for the Simulator SDK with both gems, stage under `Vendor/` |
| `rake ios:tiltsynth:gen` | generate `TiltSynth.xcodeproj` from `project.yml` |
| `rake ios:tiltsynth:build` | build for the Simulator |
| `rake ios:tiltsynth:run` | boot a Simulator, install, launch |
| `rake ios:tiltsynth:observe` | launch repeatedly on a pinned Simulator and classify each run |
| `rake ios:tiltsynth:device:lib` | cross-build `libmruby.a` for the device SDK (iphoneos arm64) |
| `rake ios:tiltsynth:device:check` | link for a generic device without signing (no hardware needed) |
| `rake ios:tiltsynth:device:build` | build signed for a connected device |
| `rake ios:tiltsynth:device:run` | install and launch on the connected device |
| `rake ios:tiltsynth:device:all` | the full device pipeline |

## Scope

This is a proof of concept for putting the musical mapping in Ruby, and it
deliberately stops there:

- no GPS altitude or barometer input;
- no continuous portamento — the scale is quantized in discrete steps;
- no scale-switching UI, no microphone input, no recording;
- no rp2040 or esp32 port of the two gems.
