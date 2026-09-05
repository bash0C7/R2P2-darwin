# ble-subscribe — a BLE central that subscribes to a peripheral

日本語版: [README_jp.md](README_jp.md)

A Mac acting as a BLE central, written in PicoRuby. The script scans for a
peripheral whose name includes `TARGET_NAME` (default `PicoRuby`), connects,
discovers its services, subscribes to the first characteristic that can notify,
and prints each notification until the scan window closes.

The intended peer is picoruby-ble's peripheral example
(`mrbgems/picoruby-ble/example/peripheral-central/peripheral/app.rb`) on a
Pico W / Pico 2 W: it advertises as `PicoRuby BLE` and, once subscribed,
notifies the on-chip temperature every 10 seconds as a little-endian `int16` in
units of 0.01 °C. Any peripheral with a notifying characteristic works; set
`TARGET_NAME` to part of its name.

CoreBluetooth is driven through picoruby-ble's darwin port. The script uses the
same `BLE` API as the rp2040 examples and contains no platform-specific code.

## Running it

The host build with the BLE config produces `./build/host/bin/picoruby`:

```sh
MRUBY_CONFIG=build_config/r2p2-picoruby-darwin-ble.rb rake macos:build
```

macOS TCC only lets a process use CoreBluetooth when LaunchServices started it
from an app bundle that declares `NSBluetoothAlwaysUsageDescription` (see
[macOS host](../../../README.md#macos-host)). Wrap the binary once:

```sh
app=~/Applications/PicoRubyBLE.app
mkdir -p "$app/Contents/MacOS"
cp build/host/bin/picoruby "$app/Contents/MacOS/picoruby-bin"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>picoruby-bin</string>
  <key>CFBundleIdentifier</key><string>com.example.picorubyble</string>
  <key>CFBundleName</key><string>PicoRubyBLE</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Talks to BLE peripherals from PicoRuby.</string>
</dict>
</plist>
PLIST
codesign --force --deep -s - "$app"
```

Then launch the script through the bundle. `open` needs absolute paths, and the
first launch asks for Bluetooth permission:

```sh
open -W -a "$app" --stdout /tmp/ble-subscribe.log --stderr /tmp/ble-subscribe.log \
  --env TARGET_NAME=PicoRuby --args "$PWD/examples/macos/ble-subscribe/ble-subscribe.rb"
cat /tmp/ble-subscribe.log
```

`SCAN_MS` (default `40000`) bounds the whole run: the scan, the discovery, and
the time spent waiting for notifications.

## What the script does

- `advertising_report_callback` takes the first report whose name includes
  `TARGET_NAME` and calls `connect`; the running `scan` loop then discovers the
  services.
- When the discovery state machine reaches `:TC_IDLE`, `packet_callback` finds
  the first characteristic with `NOTIFY` in its properties, locates its Client
  Characteristic Configuration descriptor (UUID 0x2902) by its 128-bit UUID,
  and writes `01 00` to it with
  `write_characteristic_descriptor_using_descriptor_handle`.
- Every `GATT_EVENT_NOTIFICATION` (0xA7) is decoded from the event bytes —
  value handle at offset 4, length at 6, value from 8 — and printed.
- `scan` runs with `stop_state: :no_stop`, so the link stays up until `SCAN_MS`
  expires; `start` then powers the radio off.

A run against the peripheral example on a Pico 2 W (`35 0C` is 3125, i.e. 31.25 °C):

```
Event Type: connectable_advertising_ind
Address Type: random
Address: 97:4B:CD:F9:F5:B7
RSSI: -45
Reports:
  complete_local_name: "PicoRuby BLE"(len 12)
Subscribing to value handle 3 through CCCD handle 4
Notification from handle 3: "5\f" (35 0C)
Notification from handle 3: "\x92\f" (92 0C)
Notification from handle 3: "\x92\f" (92 0C)
```
