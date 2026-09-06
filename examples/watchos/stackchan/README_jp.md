# Watch Stack-chan

watchOS単体で動くStack-chan操作アプリ。PicoRuby VMがApple Watch上で動き、
picoruby-bleのcentralロールをCoreBluetooth経由で直接駆動する。iPhoneのcompanion
アプリは無い。[`../../ios/stackchan`](../../ios/stackchan) のsubsetで、操作は3つ。

- **Face** — たのしそうな顔2パターン（`smile` / `joy`）をトグル
- **LED** — ランダムな色でblink開始、もう一度で停止
- **ぐるっと** — 1タップで 左 → 右 → 上 → ニュートラル

speak（字幕 + mu-law音声）とtorque、touchイベントはこのexampleのスコープ外。
それらはiOS版が持つ。

## なぜforkにwatchOS向けの変更が要るのか

watchOSは`CBPeripheralManager` / `CBMutableService` / `CBMutableCharacteristic`
の初期化子を`API_UNAVAILABLE`と宣言しているため、picoruby-bleのDarwin portは
peripheralバックエンドをwatchOS向けにコンパイルできない。`bash0C7/picoruby`の
`port-darwin`では`PicoBLEPeripheral.swift`を`#if !os(watchOS)`で囲い、
`pble_peripheral_*`のexportをno-op stubにしてある — `ble_peripheral.c`は
watchOSでもアーカイブに入りこれらを参照するので、ロールが無くてもシンボルは
必要になる。centralロールはwatchOSで完全に利用できる。

## 実機なしでワイヤ形式を検証する

フレームエンコーダは素のRubyなので、host CRubyは縮小PicoRuby VMとbyte単位で
同じフレームを作る。

```
ruby examples/watchos/stackchan/test_frames.rb   # 全部 PASS
```

## Simulator

```
rake watchos:stackchan:all     # lib -> gen -> build -> run
```

SimulatorにはBluetoothの無線が無いので、**Connectが「not found」で終わるのが
正しい挙動**。Simulatorで実証できるのは、VMがbootすること、`app.rb`がアプリ内で
コンパイルされること、各コントロールがVMへ届くこと。VMの出力はこれで読む。

```
UDID=$(xcrun simctl list devices available | grep -m1 "Apple Watch" | grep -o '[0-9A-F-]\{36\}')
xcrun simctl spawn "$UDID" log show --last 5m \
  --predicate 'eventMessage CONTAINS "WatchStackchan"' --style compact
```

## 実機のApple Watch

```
rake watchos:stackchan:device:lib     # arm64_32 の libmruby.a（BLE込み）
rake watchos:stackchan:device:check   # 署名なしでgeneric watch向けにリンク（実機不要）
rake watchos:stackchan:device:all     # lib -> gen -> build -> run（ペアリング済みの接続中の実機が要る）
```

## UIがVMの出力をどう読むか

`app.rb`は書き込んだBLEフレームを毎回echoするので、`vm_call`のcaptured output
は1行ではない。各dispatcherメソッドはprefix付きの状態行も出し、SwiftUI層は
出力の各行からそのprefixを探す。

| call | 状態行 |
|---|---|
| `connect` | 成功時`Connected; RX value_handle bound` |
| `face_toggle` | `face:smile` / `face:joy` |
| `led_toggle` | `led:on:<color>` / `led:off` |
| `head_sweep` | `head:done` |

`connect`はスキャンの間（10秒）、`head_sweep`は約1.8秒、VMスレッドをブロック
するので、UI側で両方single-flightにしてある。
