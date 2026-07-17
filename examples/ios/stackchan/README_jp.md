# stackchan — Ruby で書いた Stack-chan BLE central

English: [README.md](README.md)

`stackchan-picoruby` firmware で動く
[Stack-chan](https://github.com/meganetaaan/stack-chan) ロボットに接続し、
顔・LED・首サーボ・トルクを Nordic UART Service (NUS) 越しに操作する
PicoRuby 製の BLE central です。BLE のロジックはすべて `app.rb` にあり、
Swift は VM のホストとボタンタップの転送だけを担当します。

## 仕組み

`app.rb` は同梱の固定 Ruby です。ユーザーが編集することも、ダウンロードで
差し替わることもありません。PicoRuby はアプリ自身の挙動を書くための実装言語
にすぎず、App Review Guideline 2.5.2 に抵触しない構成です。

- `picoruby-ble` の central role (scan -> connect -> GATT discovery -> NUS RX
  write) を Darwin / CoreBluetooth port で駆動します。Swift 側に
  CoreBluetooth のコードはありません。
- `picoruby-ble` の mrblib が必要とする stdlib gem (`mruby-pack`、
  `mruby-string-ext`、`mruby-sprintf`) を、他の example と共有する最小の
  base config には触れず、example 専用の build config で追加しています。
- frame codec は host CRuby (`test_frames.rb`) で検証でき、BLE ハードウェアを
  必要としません。

```
ContentView.swift  (buttons)
      │  vm_call(method, arg)
      ▼
VMExecutor.swift   (single VM thread)
      │  C bridge
      ▼
app.rb  $app = Stackchan.new
  Stackchan#connect   → RealBleLink#connect
  Stackchan#face/led/head/torque → RealBleLink#write → BLE::write_value_of_characteristic_without_response
      │
      ▼
picoruby-ble (Darwin port)  →  PicoBLEDarwin Swift package  →  CoreBluetooth
```

- `BLE_AVAILABLE` は起動時に判定されます。デバイス / Simulator (BLE リンク
  済み) では true になり `RealBleLink` が無線を駆動、host CRuby
  (`test_frames.rb`) では false になり、記録用の `BleLink` スタブが frame を
  捕捉してアサーションに使われます。
- `VMExecutor` が唯一の直列 VM スレッドを所有し、周期的に `tick` を積み
  ます。接続中は `Stackchan#tick` が BLE イベントをポンプします。
- NUS RX handle が bind される前に書かれた frame はキューに溜まり、
  `connect` 成功時にまとめて送出されます。

## ハードウェア

BLE リンクの両端に実機が必要です。

- iOS 17+ の iPhone を使います (BLE 対応モデルならどれでも可)。
- Stack-chan ロボットには `stackchan-picoruby` firmware を書き込んでおきます。
  `StackChan-PicoRuby-<suffix>` という名前で advertise し、NUS を公開します。

## 操作

各ボタンは `vm_call` を 1 回 VM スレッドに積み、エンコード済みの frame が
NUS RX characteristic に書き込まれます。

- Face — neutral / smile / joy / surprised / sad / angry: `<F:N>` を送信
  (N は顔の index)。
- LED — red / green / blue / yellow / white / off:
  `<L:1,R:r,G:g,B:b,S:B,M:s>` を送信 (両側・solid mode)。
- Head — Left: yaw 左 40°、400 ms。
- Head — Center: yaw 0°、pitch 0°、400 ms (リセット)。
- Head — Right: yaw 右 40°、400 ms。
- Head — Up: pitch 上 30°、400 ms。
- Torque — On / Off: サーボの有効化 / 無効化。

## frame codec

frame のエンコードはすべて `app.rb` の `FrameCodec` が行います。codec は
host CRuby でそのまま動くので、デバイスもビルドも BLE ハードウェアも無しで
検証できます。

```
ruby examples/ios/stackchan/test_frames.rb   # 全て PASS、BLE ハードウェア不要
```

- API の "left"/"right" は Stack-chan 自身から見た向き (自分の手) です。
  firmware 側の配線が左右逆なので、"left" はワイヤ上では `R` になります。
  `SIDE_TO_CHAR` はハードウェアに合わせた仕様であり、「修正」しては
  いけません。

## build config

`build_config/r2p2-picoruby-ios-stackchan-{device,sim}.rb` が base VM に以下を
追加します。

- `picoruby-ble` — `conf.ports :darwin` で Darwin port を選択し、宣言されている
  `picoruby-mbedtls` / `picoruby-cyw43` への依存を除去 (Darwin の C コードは
  どちらも参照しないため)。
- `mruby-string-ext` — `ble_utils.rb` が使う `String#<<`。
- `mruby-pack` — `ble_utils.rb` が使う `Array#pack` / `require 'pack'`。
- `mruby-sprintf` — `ble_central.rb` の debug 出力が使う `Kernel#sprintf`。

この stdlib gem 3 つは PicoRuby の `stdlib.gembox` (vm_mruby branch) に含まれ、
rp2040 向けビルドには必ず入っています。base の iOS config は REPL を軽く保つ
ためにこれらを省いており、この example が example 専用に追加しています。

## ビルドと実行

### Simulator

`rake ios:stackchan:all` (lib -> gen -> build -> run) です。Simulator では
応答する peripheral がいないため、scan は単にタイムアウトします。

### 実機

初回の実機ビルドの前に、`project.yml` の `DEVELOPMENT_TEAM: YOUR_TEAM_ID` を
自分の Team ID に置き換えてください。詳細は
[実機ビルド](../../../README_jp.md#実機ビルド) を参照してください。

```
# 1. 接続中の iPhone 向けに BLE 入りの libmruby.a をビルド
rake ios:stackchan:device:lib

# 2. Xcode プロジェクトを生成・署名してビルド
rake ios:stackchan:gen
rake ios:stackchan:device:build

# 3. インストールして起動 (コンソール出力をストリーム表示)
rake ios:stackchan:device:run

# まとめて 1 ステップで:
rake ios:stackchan:device:all
```

初回起動時に iOS が Bluetooth の許可を求めるので、許可してください。

## 既知の制約

実機で動かす際の制約です。

- Bluetooth 許可: `project.yml` で `NSBluetoothAlwaysUsageDescription` を設定
  しています。これが無いと `CBCentralManager` が `.poweredOn` に到達せず、
  scan は何もしません。
- scan タイムアウト: `scan(timeout_ms: 30000)` は connect -> GATT discovery ->
  TC_IDLE の全サイクル (100 ms ポーリングでの複数回の BLE 往復) をカバー
  します。短縮は実機で計測してからにしてください。
- Free Personal Team: iOS のインストール可能アプリは 3 つまでです。install
  error 3002 が出たら
  `xcrun devicectl device uninstall app --device <UDID> <bundleid>` で 1 つ
  削除してください。
- デバイスのロック: 画面がロックされていると起動が
  `FBSOpenApplicationServiceErrorDomain error 1` で失敗します。先にロックを
  解除してください。
