# stackchan — RubyでStack-chanのBLEセントラルを書く

English: [README.md](README.md)

`stackchan-picoruby`ファームウェアで動く
[Stack-chan](https://github.com/meganetaaan/stack-chan)ロボットへ接続し、Nordic
UART Service（NUS）経由で表情・LED・首のサーボ・トルクを操るPicoRubyのBLE
セントラルです。BLEのロジックはすべて`app.rb`にあり、SwiftはVMをホストして
ボタンのタップを転送します。

[virtual-peripheral](../virtual-peripheral/README_jp.md)が端末をBLEの
*ペリフェラル*にするのに対し、このexampleは*セントラル*にします。picoruby-ble
darwin portのもう半分を、実機相手に動かすものです。

## しくみ

`app.rb`は同梱の固定Rubyです。ユーザが編集するものでもダウンロードするものでも
なく、PicoRubyは単にこのアプリ自身の振る舞いの実装言語です。App Review Guideline
2.5.2に抵触しないのはそのためです。

```
ContentView.swift  （ボタン）
      │  vm_call(method, arg)
      ▼
VMExecutor.swift   （単一の VM スレッド）
      │  C ブリッジ
      ▼
app.rb   $app = Stackchan.new
  Stackchan#connect              → RealBleLink#connect
  Stackchan#face/led/head/torque → RealBleLink#write
                                 → BLE::write_value_of_characteristic_without_response
      │
      ▼
picoruby-ble（darwin port）→ PicoBLEDarwin Swift パッケージ → CoreBluetooth
```

- セントラルの役割（スキャン、接続、GATTディスカバリ、NUS RXへのwrite）は
  darwin / CoreBluetooth port経由で駆動します。SwiftのCoreBluetoothコードは
  ありません。
- `VMExecutor`が単一のシリアルVMスレッドを持ち、周期的な`tick`を投げます。
  `Stackchan#tick`は接続中BLEイベントを汲み続けます。
- NUS RXのハンドルが結び付く前に書かれたフレームはキューされ、`connect`成功時に
  flushされます。早めに押したボタンが落ちません。

### 1つのソースファイル、2つの実行環境

`app.rb`はアプリ内でもホストCRubyでも動き、どちらかをロード時に判定します。

```ruby
BLE_AVAILABLE = ...   # このVMに picoruby-ble の BLE クラスがリンクされているか
```

実機やSimulatorではBLE gemがリンクされているので`BLE_AVAILABLE`は真になり、
`RealBleLink`が無線を駆動します。ホストCRubyでは偽になり、記録役の`BleLink`
スタブがフレームを捕まえてアサーションに使えるようにします。`BLE`クラスへの参照は
すべてこの定数でガードされており、このファイルに`require_relative`もモジュールの
名前空間も無いのはそのためです。両方の世界で丸ごと1ソースとして読まれます。

## フレームのコーデック

`app.rb`内の`FrameCodec`が全フレームをエンコードします。上記の切り分けにより、
デバイスもビルドもBLEハードウェアも無しにホストCRubyで走ります。

```sh
ruby examples/ios/stackchan/test_frames.rb   # 全部 PASS
```

意図的な非対称が1つあり、触ってはいけません。APIの`"left"` / `"right"`は
Stack-chan自身の視点（その手）であり、ファームウェア側の配線が逆になっているので、
`"left"`は電文上`R`になります。`SIDE_TO_CHAR`はハードウェアに合わせてあり、
load-bearingです。「直さ」ないでください。

## ハードウェア

BLEリンクの両端が実機です。

- iOS 17以降のiPhone（BLEが使えるモデルなら何でも）。
- `stackchan-picoruby`ファームウェアを書き込んだStack-chanロボット。
  `StackChan-PicoRuby-<suffix>`としてアドバタイズし、NUSを公開します。

## 操作

ボタン1つがVMスレッドへ`vm_call`を1回投げ、エンコードされたフレームがNUS RX
キャラクタリスティックへ書かれます。

| 操作 | フレーム |
|---|---|
| 表情 — neutral / smile / joy / surprised / sad / angry | `<F:N>`（Nは表情index） |
| LED — 赤 / 緑 / 青 / 黄 / 白 / off | `<L:1,R:r,G:g,B:b,S:B,M:s>`（両側、solidモード） |
| 首 — Left | yawを左へ40°、400ms |
| 首 — Center | yaw 0°、pitch 0°、400ms（リセット） |
| 首 — Right | yawを右へ40°、400ms |
| 首 — Up | pitchを上へ30°、400ms |
| トルク — On / Off | サーボの有効・無効 |

## ビルド設定

`build_config/r2p2-picoruby-ios-stackchan-{sim,device}.rb`は縮小版のgem集合から
出発して、次を足します。

- **`picoruby-ble`**。darwin portは`conf.ports :darwin, :posix`で選ばれます。
  `picoruby-cyw43`依存（rp2040の無線）はgem自身の`build.darwin?`ガードで落ちます。
  `picoruby-mbedtls`依存は残り、残さねばなりません。`ble.rb`が起動時に
  `require 'mbedtls'`し、GATTデータベースのハッシュが`MbedTLS::CMAC`を使うため、
  外すとBLEのRuby層が丸ごと読み込まれず、`BLE.new`が
  `wrong number of arguments`で落ちます。mbedtlsとrngのdarwin portはiOS向けに
  問題なくビルドでき、エントロピーは`SecRandomCopyBytes`から取ります。アプリは
  そのために`-framework Security`をリンクします。
- **`mruby-string-ext`** — picoruby-bleの`ble_utils.rb`が使う`String#<<`。
- **`mruby-pack`** — 同じく`ble_utils.rb`の`Array#pack`と`require 'pack'`。
- **`mruby-sprintf`** — `ble_central.rb`のデバッグ用文字列補間が使う
  `Kernel#sprintf`。

このmruby gem 3つはpicorubyが同梱するmrubyツリー
（`mrbgems/picoruby-mruby/lib/mruby/mrbgems`）にあり、ディレクトリ指定で取り込み
ます。rp2040のビルドはPicoRubyの`stdlib` gembox経由でこれらを得ますが、縮小版の
gem集合はリンクを小さく保つためgemboxを省いています。そこでこのexampleが、共有の
ベースではなく自分の設定に閉じた形で足しています。

## ビルドと実行

### Simulator

```sh
rake ios:stackchan:all      # lib -> gen -> build -> run
```

Simulatorでは応答するペリフェラルが居ないので、スキャンは単にタイムアウトします。
このターゲットで確認できるのはビルドがリンクしVMが動くことまでです。

### 実機

最初の実機ビルドの前に、`project.yml`の`DEVELOPMENT_TEAM: YOUR_TEAM_ID`を自分の
Team IDに置き換えてください。詳細は
[実機で動かす](../../../README_jp.md#実機で動かす)を参照。

```sh
rake ios:stackchan:device:all
```

段階的に実行する場合:

```sh
rake ios:stackchan:device:lib     # device SDK 向けの BLE 入り libmruby.a
rake ios:stackchan:gen            # Xcode プロジェクトを生成
rake ios:stackchan:device:build   # 署名してビルド
rake ios:stackchan:device:run     # インストールして起動（コンソールを流す）
```

初回起動時にiOSがBluetooth許可を尋ねるので、許可してください。

## 実機で動かすときの制約

- **Bluetooth権限**。`project.yml`に`NSBluetoothAlwaysUsageDescription`を
  設定しています。無いと`CBCentralManager`が`.poweredOn`に到達せず、スキャンが
  no-opになります。
- **スキャンのタイムアウト**。`scan(timeout_ms: 30000)`は接続 → GATT
  ディスカバリ → アイドルまでのサイクル全体を覆う必要があり、100ms pollingでの
  BLE往復が複数回入ります。短くするのは自分のハードウェアで実測してからに
  してください。
- **無料Personal Teamのアプリ数上限**。iOSは3つまでです。インストールエラー3002が
  上限到達のサインで、
  `xcrun devicectl device uninstall app --device <UDID> <bundle-id>`で1つ外します。
- **デバイスのロック**。画面がロックされていると
  `FBSOpenApplicationServiceErrorDomain error 1`で起動に失敗します。先に解除して
  ください。
