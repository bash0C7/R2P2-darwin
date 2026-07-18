# virtual-peripheral — Ruby で書く BLE ペリフェラル

English: [README.md](README.md)

PicoRuby 主導の仮想 BLE ペリフェラルです。BLE セントラルをデバッグするためのテストスタブとして使えます。`PBLE-TEST` という名前で Heart Rate GATT サービスを advertise し、read への応答・write の処理・notification の送出まで、その振る舞いのすべてを `app.rb` が決めます。Apple の CoreBluetooth framework は picoruby-ble の Darwin port 越しに駆動され、アプリ側に Swift の CoreBluetooth コードはありません。

## 仕組み

GATT サーバとしての振る舞いはすべて `app.rb` にあります。`BLE` のサブクラスです。

```ruby
class VirtualPeripheral < BLE
  def initialize
    profile = build_profile
    super(:peripheral, profile)
```

- いつ advertise するか、read に何を返すか、write をどう処理するか、いつ notify するかを Ruby が決めます。
- picoruby-ble の peripheral API (`advertise`、`push_read_value`、`pop_write_value`、`notify`、`request_can_send_now_event`) を呼び、Darwin port (`ports/darwin/`、後述の「依存関係」参照) がそれを `CBPeripheralManager` の操作に変換します。
- この example の Swift は VM ホスト (VM を tick するタイマー) と読み取り専用のログ表示だけです。
- 「この BLE デバイスが何をするか」は rp2040 ボード上と全く同じく Ruby です。同じ `app.rb` と同じ picoruby-ble API がどちらのターゲットでも動き、違うのは下層の port (ここでは CoreBluetooth、rp2040 では BTstack) だけです。

### tick モデル

`app.rb` は起動時に一度だけ開かれる永続 VM の中で動きます。ブロックする `BLE#start` ループはなく、`VMExecutor` が 100 ms 周期のタイマー (picoruby-ble の `POLLING_UNIT_MS` に合わせた値) で `vm_call("tick")` を呼びます。各 `tick` では次の処理が走ります。

- `pop_packet` が CoreBluetooth イベントを 1 件取り出します (Darwin ではあわせて read cache / write queue を VM スレッド上で同期します)。
- `packet_callback` がイベントの先頭バイトで分岐します。
  - `0x60` — 無線が有効になったので AD データを advertise します。
  - `0xB5` — MTU 交換完了。セントラルが接続しています。
  - `0xB7` — CAN_SEND_NOW。次の心拍値を積んで `notify` します。
  - `0x05` — セントラルが切断しました。
- CCCD ハンドルへの `pop_write_value` で subscribe / unsubscribe を切り替えます。
- control ハンドルへの `pop_write_value` で Heart Rate Control Point への write を受け取ります。

`tick` は値を返しません。ログ行を `print` し、`vm_call` がそれを captured stdout として返して画面上のログになります。

### profile は Ruby が組み立てます (pack / chr なし)

ここで動く PicoRuby の `String` / `Array` には `Array#pack` / `String#<<` / `Integer#chr` がありません (CRuby ではなく PicoRuby です)。そこで `app.rb` は BTstack の ATT-DB `profile_data` と AD-TLV の `adv_data` を、ビット演算による等価コードで実行時に組み立てます。

- 整数から 1 バイト文字列へ: 固定の 256 バイトテーブルのスライス `BYTE_TABLE[n & 0xff, 1]` を使います。`pack("C")` / `chr` の代役です (バイトを実体化するにはそのバイトを既に含む文字列が必要なので、このリテラルテーブル 1 つだけは省けません)。
- 16 ビットリトルエンディアン: `byte(v & 0xff) + byte((v >> 8) & 0xff)`。
- 連結: `+`。

`build_profile` / `build_adv` は `BLE::GattDatabase` / `BLE::AdvertisingData` の処理 (add_service / add_characteristic / add_descriptor、ハンドル割り当て、長さプレフィックス) をなぞるので、生成されるバイト列は rp2040 でコンパイルされるものと同一です。オフラインの生成手順も追加の gem も不要で、ボード上と同じようにデバイス上の Ruby が profile を組み立てます。

## 公開する profile の変更

サービス・キャラクタリスティック・advertise 名を変えるには、`app.rb` の `build_profile` / `build_adv` と `HR_*` ハンドル定数を直接編集します。

- ハンドルは組み立て順に割り当てられます: service=1、0x2A37 decl=2、value=3、CCCD=4、0x2A39 decl=5、value=6。
- ハンドルは 255 以下に保ってください。Darwin port のイベントレイアウトはハンドルを 1 バイトで読みます。

## ファイル構成

VM bridge と build config は repo root (`../../../bridge`、`../../../build_config`) にあり、このディレクトリにあるのはアプリ本体・`app.rb`・`tools/` ヘルパーです。

- `app.rb` — ペリフェラル本体。`build_profile` / `build_adv` (pack を使わない実行時ビルダー) と、`tick` / `packet_callback` / read / write / subscribe / notify の実挙動。
- `Sources/VMExecutor.swift` — VM (`vm_open` / `vm_call`) と tick タイマーを保有する単一のシリアルスレッド。
- `Sources/ContentView.swift` — tick が print した出力を流す読み取り専用ログ。
- `Sources/App.swift` — `@main` のアプリエントリ。
- `Sources/VirtualPeripheral-Bridging-Header.h` — C の VM ブリッジを Swift に公開するヘッダ。
- `tools/ble_write.swift` — `PBLE-TEST` をスキャンして接続し、read・subscribe・write を行う macOS の BLE セントラル。
- `project.yml` — xcodegen プロジェクト。`PicoBLEDarwin` を link + embed し、Bluetooth の usage string を宣言します。

## 依存

この example には picoruby-ble の CoreBluetooth Darwin port が必要です。port は `bash0C7/picoruby` fork の `port-darwin` branch にあります。この branch は upstream master に、picoruby-ble の `ports/darwin/` (CoreBluetooth 上の BLE peripheral / central port) と、C port が呼び出しアプリがリンクする `PicoBLEDarwin` Swift package (`ports/darwin/ext`) を加えた完全な picoruby ツリーです。

- この fork と branch が repo の default `PICORUBY_REPO` / `PICORUBY_REF` です。通常の checkout で `rake setup` を実行すれば `vendor/picoruby` に fetch されるので、追加で clone するものはありません。
- build config と `project.yml` は picoruby-ble を `vendor/picoruby` から読みます。
- upstream master に Darwin BLE port はありません。別のツリーを fetch する場合は env で上書きします: `PICORUBY_REPO=https://github.com/picoruby/picoruby.git PICORUBY_REF=master rake setup`
- picoruby-ble gem を別の場所に置いている場合は、`PICORUBY_BLE_GEMDIR` で gem ディレクトリだけを上書きできます。

## ビルドと実行

Simulator と接続した実機の両方で動かせます。3 つ目の task は macOS 側のセントラルヘルパーを実行します。

### Simulator

```sh
rake ios:vperiph:all          # Simulator パイプライン: lib -> gen -> build -> run
```

- Simulator でも VM は起動して `app.rb` は動きますが、Simulator の CoreBluetooth は `poweredOn` に到達しないため、advertise を含む無線の挙動には実機が必要です。

### 実機

初回の実機ビルドの前に、`project.yml` の `DEVELOPMENT_TEAM: YOUR_TEAM_ID` を自分の Apple Team ID に置き換えてください。詳細は [実機ビルド](../../../README_jp.md#実機ビルド) を参照してください。

```sh
rake ios:vperiph:device:all   # 接続した実機: build、署名、install、launch
```

`rake ios:vperiph:write` は `tools/ble_write.swift` をビルドして実行する、ペリフェラルを叩く macOS BLE セントラルヘルパーです。

```sh
rake ios:vperiph:write        # ペリフェラルを叩く macOS BLE セントラルヘルパー
```

`WRITE_HEX`・`TARGET_NAME`・`APP_SERVICES` は環境変数で渡せます。たとえば `WRITE_HEX=01 rake ios:vperiph:write` は Heart Rate Control Point に `0x01` を書き込み、`app.rb` がそのバイト列をログに出して模擬心拍数をリセットします。
