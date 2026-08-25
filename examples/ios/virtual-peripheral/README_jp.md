# virtual-peripheral — RubyでBLEペリフェラルを書く

English: [README.md](README.md)

iPhoneをBLEのGATTペリフェラルとして動かすexampleです。判断はすべてRuby側で
行います。`PBLE-TEST`という名前でHeart Rateサービスをアドバタイズし、readに
応答し、writeを処理し、notifyを流します。BLEセントラルをデバッグしていて実機の
挙動に依存したくないとき、テスト用スタブとして使えます。

AppleのCoreBluetoothは picoruby-ble のdarwin port経由で駆動します。アプリ側に
SwiftのCoreBluetoothコードは1行もありません。

## しくみ

GATTサーバの振る舞いはすべて`app.rb`に、`BLE`のサブクラスとして書かれています。

```ruby
require "ble"

class VirtualPeripheral < BLE
  def initialize
    db = BLE::GattDatabase.new do |gatt|
      gatt.add_service(GATT_PRIMARY_SERVICE_UUID, HR_SERVICE) do |service|
        ...
      end
    end
    super(:peripheral, db.profile_data)
```

- いつアドバタイズするか、各readが何を返すか、writeにどう応えるか、いつnotifyを
  出すかは、すべてRubyが持ちます。
- Rubyが呼ぶのは picoruby-ble のペリフェラルAPI（`start`、`advertise`、
  `push_read_value`、`pop_write_value`、`notify`、
  `request_can_send_now_event`）で、darwin portがそれを
  `CBPeripheralManager`の操作へ変換します。
- ここでのSwiftはVMのホスト（VMを叩くタイマー）と読み取り専用のログビューだけです。
- 「このBLEデバイスは何をするのか」はRubyの問いです。rp2040ボード上でもまったく
  同じで、同じ`app.rb`が同じ picoruby-ble APIに対して動きます。違うのは下の
  portだけ（ここではCoreBluetooth、rp2040ではBTstack）。

### イベントループ

`app.rb`は起動時に1度開かれる永続VMの中で動きます。`BLE#start(timeout_ms)`が
picoruby-ble の正統なイベントループで、無線をonにし、内部イベントキューでblockし、
イベントをdispatchし、タイムアウトで無線をoffにします。blockが許されるのは、
ブリッジがすべての`vm_call`をmrubyのtask内でdispatchするからです。popはroot
contextでraiseせずスケジューラ上でparkします。

`VMExecutor`は`vm_call("tick")`を継続的に呼び、`tick` 1回が
`start(WINDOW_MS)`の有界ウィンドウ1つ（1000ms）に対応します。したがって
ペリフェラルは実時間のほぼ全域をイベントループの中で過ごします。ウィンドウ内では:

- `packet_callback`がportのイベントを受け取り、先頭バイトで分岐します。

  | バイト | 意味 | Rubyがやること |
  |---|---|---|
  | `0x60` | サービス登録完了、無線が動いている | ADデータをアドバタイズ |
  | `0xB5` | MTU交換完了 | セントラルが居る |
  | `0xB7` | CAN_SEND_NOW | 次のHR値をpushして`notify` |
  | `0x05` | 切断 | アドバタイズ状態へ戻る |

- `heartbeat_callback`が約1Hzで定常処理をします。CCCDハンドルへの
  `pop_write_value`がsubscribe / unsubscribeを切り替え、controlハンドルへの
  `pop_write_value`がHeart Rate Control Pointのwriteを受け取り、subscribe中は
  `request_can_send_now_event`のペースを作ります（1拍につきnotify 1回）。

ウィンドウを閉じると無線がoffになりCoreBluetoothのアドバタイズも止まります。
次の`tick`が入り口で張り直すので、アドバタイズの再開はウィンドウあたり高々1回
です。`tick`は値を返さずログ行を`print`し、それを`vm_call`が捕捉stdoutとして
返して画面のログになります。

### プロファイルは起動時にデバイス上で組み立てられる

`BLE::GattDatabase`がBTstackのATT-DB `profile_data`を、
`BLE::AdvertisingData`がAD-TLVの`adv_data`を組み立てます。rp2040が使うのと同じ
ビルダが、事前に焼き込まれるのではなく起動時に端末上で走ります。

これらは`Array#pack`や`String#setbyte`などを必要とするため、このexampleの
ビルド設定は縮小版のgem集合に`mruby-pack`・`mruby-string-ext`・`mruby-sprintf`を
足しています。ATTハンドルはハードコードせず`db.handle_table`から読み戻します。

```ruby
hr = db.handle_table[HR_SERVICE][HR_MEASUREMENT]
@meas_handle = hr[:value_handle]
@cccd_handle = hr[CLIENT_CHARACTERISTIC_CONFIGURATION]
```

## 公開プロファイルを変える

`app.rb`の`BLE::GattDatabase.new`ブロックと`BLE::AdvertisingData.build`ブロックを
編集します（サービス、キャラクタリスティック、アドバタイズ名）。ハンドルは
`handle_table`経由でビルド順に自動追従するので、他に直す箇所はありません。

制約が1つ。ハンドルは255以下に保ってください。darwin portのイベント配置がこれを
1バイトとして読みます。

## ファイル

VMブリッジとビルド設定はリポジトリのルート（`../../../bridge`、
`../../../build_config`）にあります。このディレクトリにあるのはアプリと
`app.rb`、そしてヘルパツール1つです。

- `app.rb` — ペリフェラル本体。`GattDatabase`と`AdvertisingData`のプロファイル、
  tickごとの`start`ウィンドウ、そして`packet_callback` /
  `heartbeat_callback` / read / write / subscribe / notifyの実挙動。
- `Sources/VMExecutor.swift` — VM（`vm_open`、`vm_call`）とtickタイマーを持つ
  単一のシリアルスレッド。
- `Sources/ContentView.swift` — printされたtick出力の読み取り専用スクロールログ。
- `Sources/App.swift` — `@main`のエントリポイント。
- `Sources/VirtualPeripheral-Bridging-Header.h` — C VMブリッジをSwiftへ公開。
- `tools/ble_write.swift` — `PBLE-TEST`をスキャンして接続し、read / subscribe /
  writeするmacOS側BLEセントラル。
- `project.yml` — xcodegenのプロジェクト定義。`PicoBLEDarwin` Swiftパッケージを
  リンク・埋め込みし、Bluetoothの用途文字列を宣言する。

## 依存

このexampleには picoruby-ble のCoreBluetooth darwin portが要ります。
`ports/darwin/`（BLEのペリフェラル/セントラルport）と、その下の
`ports/darwin/ext`にある`PicoBLEDarwin` Swiftパッケージ（C portが呼び、アプリが
リンクする）です。

本リポジトリの既定の`PICORUBY_REPO` / `PICORUBY_REF`は既にそれらを持つツリーを
指しているので、素のチェックアウトで`rake setup`すれば足ります。追加でcloneする
ものはありません。[vendorの取得元](../../../README_jp.md#vendorの取得元)を参照。
upstreamの`picoruby/picoruby` masterにdarwinのBLE portはありません。

`PICORUBY_BLE_GEMDIR`は picoruby-ble のgemディレクトリだけを差し替えます。vendor
ツリー全体を向け替えずに、そのgemの別チェックアウトで作業したいとき用です。

## ビルドと実行

### Simulator

```sh
rake ios:vperiph:all          # lib -> gen -> build -> run
```

SimulatorでもVMは起動して`app.rb`は走りますが、SimulatorのCoreBluetoothは
`poweredOn`に到達しません。アドバタイズと無線の挙動には実機が要ります。この
ターゲットで確認できるのはビルドがリンクしVMが動くことまでです。

### 実機

最初の実機ビルドの前に、`project.yml`の`DEVELOPMENT_TEAM: YOUR_TEAM_ID`を自分の
Team IDに置き換えてください。詳細は
[実機で動かす](../../../README_jp.md#実機で動かす)を参照。初回起動時にiOSが
Bluetooth許可を1度尋ねます。

```sh
rake ios:vperiph:device:all   # lib -> gen -> build（署名）-> install -> launch
```

### Macから叩く

`rake ios:vperiph:write`は`tools/ble_write.swift`をコンパイルして実行します。
ペリフェラルをスキャンして接続し、read / subscribe / writeするmacOS側の
BLEセントラルです。

```sh
rake ios:vperiph:write
WRITE_HEX=01 rake ios:vperiph:write   # Heart Rate Control Point へ 0x01 を write
```

`WRITE_HEX`・`TARGET_NAME`・`APP_SERVICES`は環境変数で渡します。`WRITE_HEX=01`
なら`app.rb`が受け取ったバイト列をログに出し、模擬心拍値をリセットします。Mac
から端末上のRubyへ渡り、ログへ返ってくる往復が見られます。
