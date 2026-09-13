# ble-subscribe — peripheralにsubscribeするBLE central

English: [README.md](README.md)

MacをBLE centralとして動かす、PicoRubyで書いたスクリプトです。名前に
`TARGET_NAME`（既定は`PicoRuby`）を含むperipheralを探して接続し、serviceを
discoveryし、notifyできる最初のcharacteristicにsubscribeして、scanの時間枠が
閉じるまで届いたnotificationを表示します。

想定する相手はpicoruby-bleのperipheral example
（`mrbgems/picoruby-ble/example/peripheral-central/peripheral/app.rb`）を載せた
Pico W / Pico 2 Wです。`PicoRuby BLE`という名前で広告し、subscribeされると
チップ内の温度を0.01℃単位のlittle-endian `int16`として10秒ごとにnotifyします。
notifyするcharacteristicを持つperipheralなら何でも相手にできるので、名前の一部を
`TARGET_NAME`に渡してください。

CoreBluetoothはpicoruby-bleのdarwin portが駆動します。スクリプトはrp2040の
exampleと同じ`BLE` APIだけを使い、platform固有のコードを含みません。

## 動かし方

BLE configでhost buildすると`./build/host/bin/picoruby`ができます。

```sh
MRUBY_CONFIG=build_config/r2p2-picoruby-darwin-ble.rb rake macos:build
```

macOSのTCCは、`NSBluetoothAlwaysUsageDescription`を宣言したapp bundleから
LaunchServicesが起動したprocessにしかCoreBluetoothを使わせません
（[macOSホスト](../../../README_jp.md#macosホスト)参照）。binaryを一度bundleに包みます。

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

bundle経由でスクリプトを起動します。`open`には絶対パスを渡し、初回起動では
Bluetoothの許可を求められます。

```sh
open -W -a "$app" --stdout /tmp/ble-subscribe.log --stderr /tmp/ble-subscribe.log \
  --env TARGET_NAME=PicoRuby --args "$PWD/examples/macos/ble-subscribe/ble-subscribe.rb"
cat /tmp/ble-subscribe.log
```

`SCAN_MS`（既定`40000`）がscan・discovery・notification待ちを含む実行全体の
長さを決めます。

## スクリプトがしていること

- `advertising_report_callback`が名前に`TARGET_NAME`を含む最初のreportを取って
  `connect`を呼び、走っている`scan`のloopがそのままserviceをdiscoveryします。
- discoveryの状態機械が`:TC_IDLE`に達すると、`packet_callback`がpropertiesに
  `NOTIFY`を持つ最初のcharacteristicを見つけ、そのClient Characteristic
  Configuration descriptor（UUID 0x2902）を128-bit UUIDで探して、
  `write_characteristic_descriptor_using_descriptor_handle`で`01 00`を書きます。
- `GATT_EVENT_NOTIFICATION`（0xA7）はevent bytesから直接decodeします
  （offset 4がvalue handle、6が長さ、8から値）。
- `scan`は`stop_state: :no_stop`で回すので、`SCAN_MS`が尽きるまでlinkは
  張られたままです。その後`start`が無線を切ります。

Pico 2 Wのperipheral exampleを相手にした実行（`35 0C`は3125、つまり31.25℃）:

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
