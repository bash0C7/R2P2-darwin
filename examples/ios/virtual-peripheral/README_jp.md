# virtual-peripheral — Rubyで書くBLEペリフェラル

English: [README.md](README.md)

PicoRuby主導の仮想BLEペリフェラルです。BLEセントラルをデバッグするためのテストスタブとして使えます。`PBLE-TEST`という名前でHeart Rate GATTサービスをadvertiseし、readへの応答・writeの処理・notificationの送出まで、その振る舞いのすべてを`app.rb`が決めます。AppleのCoreBluetooth frameworkはpicoruby-bleのDarwin port越しに駆動され、アプリ側にSwiftのCoreBluetoothコードはありません。

## 仕組み

GATTサーバとしての振る舞いはすべて`app.rb`にあります。`BLE`のサブクラスです。

```ruby
class VirtualPeripheral < BLE
  def initialize
    db = BLE::GattDatabase.new do |gatt|
      gatt.add_service(GATT_PRIMARY_SERVICE_UUID, HR_SERVICE) do |service|
        ...
      end
    end
    super(:peripheral, db.profile_data)
```

- いつadvertiseするか、readに何を返すか、writeをどう処理するか、いつnotifyするかをRubyが決めます。
- picoruby-bleのperipheral API（`start`、`advertise`、`push_read_value`、`pop_write_value`、`notify`、`request_can_send_now_event`）を呼び、Darwin port（`ports/darwin/`、後述の「依存」参照）がそれを`CBPeripheralManager`の操作に変換します。
- このexampleのSwiftはVMホスト（VMをtickするタイマー）と読み取り専用のログ表示だけです。
- 「このBLEデバイスが何をするか」はrp2040ボード上と全く同じくRubyです。同じ`app.rb`と同じpicoruby-ble APIがどちらのターゲットでも動き、違うのは下層のport（ここではCoreBluetooth、rp2040ではBTstack）だけです。

### イベントループモデル

`app.rb`は起動時に一度だけ開かれる永続VMの中で動きます。`BLE#start(timeout_ms)`がpicoruby-bleの正規のイベントループです。無線を有効化し、内部のイベントキューでブロックし（VM bridgeがすべての`vm_call`をtask内でdispatchするので合法です）、イベントを配送し、timeoutで無線を止めます。`VMExecutor`は`vm_call("tick")`を連続的に呼び、各`tick`は1回の有界な`start(WINDOW_MS)` windowなので、ペリフェラルはほぼすべての実時間をイベントループの中で過ごします。window内では次の処理が走ります。

- `packet_callback`がportのイベントを受け取り、先頭バイトで分岐します。
  - `0x60` — サービス登録完了・無線有効。ADデータをadvertiseします。
  - `0xB5` — MTU交換完了。セントラルが接続しています。
  - `0xB7` — CAN_SEND_NOW。次の心拍値を積んで`notify`します。
  - `0x05` — セントラルが切断しました。
- `heartbeat_callback`（約1 Hz）が定常処理を行います。CCCDハンドルへの`pop_write_value`でsubscribe / unsubscribeを切り替え、controlハンドルへの`pop_write_value`でHeart Rate Control Pointへのwriteを受け取り、subscribe中は`request_can_send_now_event`を要求します — notificationはheartbeatごとに1件です。

windowが閉じると無線が止まり、CoreBluetoothのadvertiseも止まります。次のwindowの入り口（`tick`）で再advertiseするので、advertiseの再開はwindowあたり最大1回です。`tick`は値を返しません。ログ行を`print`し、`vm_call`がそれをcaptured stdoutとして返して画面上のログになります。

### profileは正規のビルダーで組み立てます

BTstackのATT-DB `profile_data`は`BLE::GattDatabase`が、AD-TLVの`adv_data`は`BLE::AdvertisingData`が組み立てます — rp2040と同じビルダーが、起動時にデバイス上で動きます。ビルダーが必要とする`Array#pack` / `String#setbyte`などはvperiphのbuild configが持っています（`mruby-pack`、`mruby-string-ext`、`mruby-sprintf`）。ATTハンドルはハードコードせず`db.handle_table`から読み戻します。

```ruby
hr = db.handle_table[HR_SERVICE][HR_MEASUREMENT]
@meas_handle = hr[:value_handle]
@cccd_handle = hr[CLIENT_CHARACTERISTIC_CONFIGURATION]
```

## 公開するprofileの変更

サービス・キャラクタリスティック・advertise名を変えるには、`app.rb`の`BLE::GattDatabase.new`ブロックと`BLE::AdvertisingData.build`ブロックを直接編集します。ハンドルは組み立て順に沿って`handle_table`から自動で得られます。

- ハンドルは255以下に保ってください。Darwin portのイベントレイアウトはハンドルを1バイトで読みます。

## ファイル構成

VM bridgeとbuild configはrepo root（`../../../bridge`、`../../../build_config`）にあり、このディレクトリにあるのはアプリ本体・`app.rb`・`tools/`ヘルパーです。

- `app.rb` — ペリフェラル本体。`GattDatabase` / `AdvertisingData`によるprofile、tickごとの`start` window、そして`packet_callback` / `heartbeat_callback` / read / write / subscribe / notifyの実挙動。
- `Sources/VMExecutor.swift` — VM（`vm_open` / `vm_call`）とtickタイマーを保有する単一のシリアルスレッド。
- `Sources/ContentView.swift` — tickがprintした出力を流す読み取り専用ログ。
- `Sources/App.swift` — `@main`のアプリエントリ。
- `Sources/VirtualPeripheral-Bridging-Header.h` — CのVMブリッジをSwiftに公開するヘッダ。
- `tools/ble_write.swift` — `PBLE-TEST`をスキャンして接続し、read・subscribe・writeを行うmacOSのBLEセントラル。
- `project.yml` — xcodegenプロジェクト。`PicoBLEDarwin`をlink + embedし、Bluetoothのusage stringを宣言します。

## 依存

このexampleにはpicoruby-bleのCoreBluetooth Darwin portが必要です。portは`bash0C7/picoruby` forkの`port-darwin` branchにあります。このbranchはupstream masterに、picoruby-bleの`ports/darwin/`（CoreBluetooth上のBLE peripheral / central port）と、C portが呼び出しアプリがリンクする`PicoBLEDarwin` Swift package（`ports/darwin/ext`）を加えた完全なpicorubyツリーです。

- このforkとbranchがrepoのdefault `PICORUBY_REPO` / `PICORUBY_REF`です。通常のcheckoutで`rake setup`を実行すれば`vendor/picoruby`にfetchされるので、追加でcloneするものはありません。
- build configと`project.yml`はpicoruby-bleを`vendor/picoruby`から読みます。
- upstream masterにDarwin BLE portはありません。別のツリーをfetchする場合はenvで上書きします: `PICORUBY_REPO=https://github.com/picoruby/picoruby.git PICORUBY_REF=master rake setup`
- picoruby-ble gemを別の場所に置いている場合は、`PICORUBY_BLE_GEMDIR`でgemディレクトリだけを上書きできます。

## ビルドと実行

Simulatorと接続した実機の両方で動かせます。3つ目のtaskはmacOS側のセントラルヘルパーを実行します。

### Simulator

```sh
rake ios:vperiph:all          # Simulatorパイプライン: lib -> gen -> build -> run
```

- SimulatorでもVMは起動して`app.rb`は動きますが、SimulatorのCoreBluetoothは`poweredOn`に到達しないため、advertiseを含む無線の挙動には実機が必要です。

### 実機

`project.yml`は実機署名用の`DEVELOPMENT_TEAM`を持っています。このrepoの所有者でない場合は自分のApple Team IDに置き換えてください。詳細は[実機ビルド](../../../README_jp.md#実機ビルド)を参照してください。

```sh
rake ios:vperiph:device:all   # 接続した実機: build、署名、install、launch
```

`rake ios:vperiph:write`は`tools/ble_write.swift`をビルドして実行する、ペリフェラルを叩くmacOS BLEセントラルヘルパーです。

```sh
rake ios:vperiph:write        # ペリフェラルを叩くmacOS BLEセントラルヘルパー
```

`WRITE_HEX`・`TARGET_NAME`・`APP_SERVICES`は環境変数で渡せます。たとえば`WRITE_HEX=01 rake ios:vperiph:write`はHeart Rate Control Pointに`0x01`を書き込み、`app.rb`がそのバイト列をログに出して模擬心拍数をリセットします。
