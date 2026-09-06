# Watch Stack-chan

A watchOS-only Stack-chan controller. The PicoRuby VM runs on the Apple Watch
and drives picoruby-ble's central role directly over CoreBluetooth — there is no
iPhone companion app. It is a subset of [`../../ios/stackchan`](../../ios/stackchan)
with four interactive rows:

- **Connect** — scans for the robot over BLE and binds its write characteristic,
  blocking for up to 10 seconds; tap this first
- **Face** — toggles between two happy faces, `smile` and `joy`
- **LED** — toggles a blink in a randomly chosen colour, and off again
- **ぐるっと (sweep)** — one tap sends left → right → up → neutral

Speak (subtitle + mu-law audio), torque, and touch events are out of scope here;
the iOS example carries those.

## Why the fork carries a watchOS change

watchOS declares the `CBPeripheralManager`, `CBMutableService` and
`CBMutableCharacteristic` initializers `API_UNAVAILABLE`, so picoruby-ble's
Darwin port cannot compile its peripheral backend for the watch. In
`bash0C7/picoruby` (`port-darwin`), `PicoBLEPeripheral.swift` is wrapped in
`#if !os(watchOS)` and the `pble_peripheral_*` exports become no-op stubs —
`ble_peripheral.c` still enters the watchOS archive and references them, so the
symbols must exist even though the role does not. The central role is fully
available on watchOS.

## Verify the wire format without a watch

The frame encoders are plain Ruby, so host CRuby produces byte-identical frames
to the reduced PicoRuby VM:

```
ruby examples/watchos/stackchan/test_frames.rb   # all PASS
```

## Simulator

```
rake watchos:stackchan:all     # lib -> gen -> build -> run
```

**Warning:** `lib` and `device:lib` (below) both stage into the same
`Vendor/lib/libmruby.a`, and whichever ran last wins silently — `ld` skips a
wrong-arch static archive instead of erroring, so a build can print
`** BUILD SUCCEEDED **` and the app still crashes at launch with a dyld
undefined-symbol error. `rake watchos:stackchan:all` always runs `lib` first,
so it is safe; running `build` or `run` alone after a `device:lib` is not.
Check with `lipo -info examples/watchos/stackchan/Vendor/lib/libmruby.a` — the
Simulator wants `arm64`.

The Simulator has no Bluetooth radio, so **Connect ending in "not found" is the
correct behaviour there**. What the Simulator does prove is that the VM boots,
`app.rb` compiles in-app, and every control reaches the VM. Read the captured VM
output with:

```
UDID=$(xcrun simctl list devices available | grep -m1 "Apple Watch" | grep -o '[0-9A-F-]\{36\}')
xcrun simctl spawn "$UDID" log show --last 5m \
  --predicate 'eventMessage CONTAINS "WatchStackchan"' --style compact
```

## Physical Apple Watch

```
rake watchos:stackchan:device:lib     # arm64_32 libmruby.a (BLE)
rake watchos:stackchan:device:check   # link for a generic watch, unsigned — no watch needed
rake watchos:stackchan:device:all     # lib -> gen -> build -> run (needs a paired, connected watch)
```

**Warning:** this shares `Vendor/lib/libmruby.a` with the Simulator build
above. `device:all` runs `device:lib` first, so it is safe; running
`device:check`, `device:build`, or `device:run` alone after a Simulator `lib`
will silently link the wrong-arch archive. Check with
`lipo -info examples/watchos/stackchan/Vendor/lib/libmruby.a` — the watch wants
`arm64_32`.

## How the UI reads the VM

`app.rb` echoes every BLE frame it writes, so the captured output of a `vm_call`
is more than one line. `face_toggle` / `led_toggle` / `head_sweep` each print a
prefixed status line, which the SwiftUI layer finds by scanning the output's
lines for that prefix; `connect`'s line instead comes from the BLE link object
as a full sentence, matched with a whole-string `contains` check:

| call | status line |
|---|---|
| `connect` | `Connected; RX value_handle bound` on success |
| `face_toggle` | `face:smile` / `face:joy` |
| `led_toggle` | `led:on:<color>` / `led:off` |
| `head_sweep` | `head:done` |

`connect` blocks the VM thread for the scan (10 s) and `head_sweep` for about
1.8 s, so both are single-flight in the UI.
