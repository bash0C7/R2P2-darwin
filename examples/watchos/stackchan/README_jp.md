# Watch Stack-chan

watchOS単体で動くStack-chan操作アプリ。PicoRuby VMがApple Watch上で動き、
picoruby-bleのcentralロールをCoreBluetooth経由で直接駆動する。iPhoneのcompanion
アプリは無い。[`../../ios/stackchan`](../../ios/stackchan)のsubsetで、操作行は4つ。

- **Connect** — BLEでロボットをスキャンし、write用characteristicを結びつける
  （最大10秒ブロック）。最初にタップする
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

**警告:** `lib`と`device:lib`（後述）は同じ`Vendor/lib/libmruby.a`にstageし、
後に走った方が黙って勝つ — `ld`はarch違いのstatic archiveをerrorにせずskipするので、
buildは`** BUILD SUCCEEDED **`のまま成立してからdyldのundefined symbolで起動時に
crashする。`rake watchos:stackchan:all`は必ず`lib`を先に実行するので安全だが、
`device:lib`の後に`build`や`run`だけを実行するのは危険。確認は
`lipo -info examples/watchos/stackchan/Vendor/lib/libmruby.a`、Simulatorが
求めるのは`arm64`。

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

**警告:** 同じ`Vendor/lib/libmruby.a`をSimulator向けbuildと共有する。
`device:all`は`device:lib`を先に実行するので安全だが、Simulator向け`lib`の後に
`device:check` / `device:build` / `device:run`だけを実行するとarch違いの
archiveがerror無しでlinkされる。実機buildの前に
`lipo -info examples/watchos/stackchan/Vendor/lib/libmruby.a`が`arm64_32`を
報告することを確認する。

## UIがVMの出力をどう読むか

`app.rb`は書き込んだBLEフレームを毎回echoするので、`vm_call`のcaptured output
は1行ではない。`face_toggle` / `led_toggle` / `head_sweep`はそれぞれprefix付きの
状態行を出し、SwiftUI層は出力の各行からそのprefixを探す。`connect`の行はBLE link
objectが出す完全な文で、UIは文字列全体への`contains`一致で判定する。

| call | 状態行 |
|---|---|
| `connect` | 成功時`Connected; RX value_handle bound` |
| `face_toggle` | `face:smile` / `face:joy` |
| `led_toggle` | `led:on:<color>` / `led:off` |
| `head_sweep` | `head:done` |

`connect`はスキャンの間（10秒）、`head_sweep`は約1.8秒、VMスレッドをブロック
するので、UI側で両方single-flightにしてある。
