# Tilt Synth — Ruby-driven Device Motion FM synthesizer

A technical PoC: tilt the iPhone and Ruby (`app.rb`) reads the Device Motion
attitude (pitch/roll) through the `picoruby-iphone-motion` gem's Darwin port,
quantizes pitch to a 2-octave C major pentatonic scale, maps roll to FM depth,
and drives an `AVAudioEngine` sine+FM oscillator through the
`picoruby-iphone-synth` gem's Darwin port. Neither gem's Swift backend
contains any music-mapping logic -- the scale, the ranges, and the tick loop
are all `app.rb`.

This mirrors picoruby-ot's `otmeiwa.rb` (sensor read) + `web/` (sensor ->
music mapping) pair, collapsed into a single native iOS app: no serial link,
no browser, no external sensor board.

## How it works

```
[CMDeviceMotion attitude]
  --> ports/darwin/motion.c   (Swift @c: pmotion_pitch/pmotion_roll/pmotion_available)
  --> include/motion.h        (port ABI)
  --> src/mruby/motion.c      (Motion class)

app.rb ($app, persistent VM, 20Hz tick via VMExecutor):
  tick:
    note  = quantize(Motion#pitch)     # nearest pentatonic step, pure Ruby
    depth = map(Motion#roll)           # pure Ruby
    Synth#note = note
    Synth#fm_depth = depth

[Synth#note= / #fm_depth= / #start / #stop]
  --> ports/darwin/synth.c    (Swift @c: psynth_set_note/psynth_set_fm_depth/...)
  --> Swift PicoSynthDarwin: AVAudioEngine + AVAudioSourceNode (sine + FM)
  --> speaker
```

There is no button: the tick timer (and therefore the synth) runs
continuously from the moment the VM boots, the same "always on" model as
`virtual-peripheral`'s poll tick.

## The gems

```
picoruby-iphone-motion/   CMDeviceMotion attitude.pitch/roll -> Motion#pitch/#roll/#available?
picoruby-iphone-synth/    AVAudioEngine sine+FM oscillator -> Synth#note=/#fm_depth=/#start/#stop
```

Both are local mrbgems (not in `vendor/picoruby`), following the same
`include/` + `src/` + `ports/darwin/` + Swift-package structure as
`picoruby-iphone-torch`.

## Testing the mapping logic without Xcode

```sh
ruby examples/ios/tilt-synth/test_mapping.rb
```

Stubs `Motion`/`Synth` (normally provided by the gems) and asserts the
quantize/clamp math, mirroring `examples/ios/stackchan/test_frames.rb`.

## Build & run

Prerequisites: full `Xcode.app`, iOS SDK, `xcodegen` (`rake check`).

### Simulator

```sh
rake ios:tiltsynth:all     # cross-build libmruby.a -> xcodegen -> build -> launch
```

**The Simulator has no Device Motion.** The app boots and the VM runs, but
`Motion#available?` is `false`, so `tick` logs "no device motion (Simulator?)"
and stays silent. This target is for verifying the build links and the VM
runs (same pattern as `iphone-torch`'s Simulator target having no torch).

### Device (actual tilt + sound)

```sh
rake ios:tiltsynth:device:all   # needs a connected, signed iOS device
```

On a real iPhone (13 Pro / 16e), tilting the phone up/down changes the pitch
in discrete pentatonic steps, and rolling it left/right changes the FM depth
(timbre). Confirming this audibly and visually is a manual step -- there is
no automated on-device test in this repo.

## Individual rake tasks

| Task | What it does |
|------|--------------|
| `rake ios:tiltsynth:lib` | cross-build `libmruby.a` (Simulator) with both gems, stage under `Vendor/` |
| `rake ios:tiltsynth:gen` | generate `TiltSynth.xcodeproj` from `project.yml` |
| `rake ios:tiltsynth:build` | build the app for the Simulator |
| `rake ios:tiltsynth:run` | boot a Simulator, install, launch |
| `rake ios:tiltsynth:device:lib` | cross-build `libmruby.a` for the device SDK |
| `rake ios:tiltsynth:device:build` | build signed for a connected device |
| `rake ios:tiltsynth:device:run` | install + launch on the connected device |

## Scope (YAGNI)

- No GPS altitude / barometer.
- No continuous portamento (discrete scale quantization only).
- No scale-switching UI, no microphone input, no recording.
- No rp2040/esp32 port.
