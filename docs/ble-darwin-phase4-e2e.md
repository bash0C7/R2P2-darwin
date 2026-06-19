# picoruby-ble Darwin step3 — Phase4 実機 E2E 手順

最終更新: 2026-06-19。central/observer v1 の実機 E2E（scan→connect→discover→read）を実 BLE peripheral で確認する手順。

## 何が済んでいて何を確認するか

**実機で検証済み（このマシン単独）**: scan 受信パス全体。central を起動すると実 radio で多数の adv report を受信し、RSSI も正しくデコードされる（CBCentralManager→`pbleAdvReport` 合成→FIFO→`__darwin_drain`→`BLE_push_event`→decoder→`AdvertisingReport`）。

**この手順で確認する（2 台目デバイス必須）**: connect→GATT discovery→characteristic/descriptor read→`:TC_IDLE`。**同一 Mac の central は同一 Mac の peripheral の advertise を受信できない**（macOS CoreBluetooth の loopback 制限）。よって peripheral は**別デバイス**で動かす。claude は電波を観測できないので、この手順は人間が実行する。

## 前提

- BLE host バイナリをビルド済み: `build-ble/host/bin/picoruby`（無ければ `PICORUBY_REPO=<local fork> PICORUBY_REF=picoruby-ble-apple_silicon-port rake refresh build:ble`）。
- 中央 Mac の Bluetooth = ON、Bluetooth 許可済み（authorization=allowedAlways)。
- peripheral 用の 2 台目デバイス（下記いずれか）。

## peripheral を用意する（どちらか）

### 選択 A: 2 台目の Mac で Swift fixture（決定論的・推奨）

fixture は `mrbgems/picoruby-ble/ports/darwin/test/pble_test_peripheral.swift`（worktree 内）。DIS(0x180A) / Manufacturer Name(0x2A29, readable) / User Description descriptor(0x2901) を持ち、local name `PBLE-TEST` で advertise する。

2 台目 Mac（Swift toolchain 必要）で:
```sh
swiftc pble_test_peripheral.swift -o pble_peri && ./pble_peri
# => [peripheral] advertising 'PBLE-TEST': service 180A / char 2A29 (read) / desc 2901
```
起動したまま放置（run loop）。期待値は char 値 `PBLE-TEST-MFR`、descriptor 値 `pble-demo-desc`。

### 選択 B: iOS の nRF Connect（導入済み）

nRF Connect for iOS は peripheral（GATT server + advertiser）に対応している。**ラベルはバージョンで変わる**が流れは次の通り（概念は不変: GATT server を構成 → advertiser packet に Complete Local Name と Connectable を入れて開始）:

1. **GATT server を構成**: メニュー（ハンバーガー or 設定）→「Configure GATT Server」。Service を 1 つ追加（Device Information `0x180A` などの標準でも、Add Custom でも可）。その下に **Characteristic を 1 つ追加し、Properties に Read を付け、value（例: テキスト `hello`）を設定**。任意で Descriptor も追加。
2. **Advertiser を作成**: 「Advertiser」タブ →「+」で新規 advertising packet → **Complete Local Name = `PBLE-TEST`** を追加（central はこの名前で選ぶ）。**Connectable を ON**。可能なら service UUID も追加（iOS は advertising 部のカスタム UUID に制限があるので入らなくても可）。
3. その advertiser を**トグル ON で送信開始**。**nRF Connect をフォアグラウンドに保つ**（背景化で local name が落ちる）。
4. char 値は任意。E2E driver の PASS 判定は「connect→discover→**characteristic 値を 1 つでも read 成功**」なので、固定値一致は不要。

名前を `PBLE-TEST` 以外にした／advertiser に名前が入らない場合は、driver が **RSSI 最強のデバイス**に繋ぐので **iOS デバイスを Mac に密着**させればよい（driver 冒頭の `TARGET_NAME` を空 `""` にすると常に最強選択）。

## central を走らせる（中央 Mac、このリポジトリで）

```sh
build-ble/host/bin/picoruby \
  /path/to/picoruby-ble-apple_silicon-port/mrbgems/picoruby-ble/ports/darwin/test/step3_e2e_central.rb
```
driver は `TARGET_NAME`（既定 `"PBLE-TEST"`）を広告するデバイスがあれば即 connect、無ければ **RSSI 最強**のデバイスに connect し、1 つの poll loop で discover→read まで駆動してツリーを表示する。`TARGET_NAME = ""` にすると常に最強選択。

期待出力（選択 A の fixture 例）:
```
[central] connecting to "PBLE-TEST" rssi=-40
[central] discovery done; state=TC_OFF services=1
  svc uuid32=0x0A180000 1..N
    char uuid32=0x292A0000 vh=3 props=2 value="PBLE-TEST-MFR"
      desc uuid32=0x01290000 handle=4 value="pble-demo-desc"
E2E PASS: connect -> discover -> read characteristic value end-to-end
```
PASS 判定は「`services>=1` かつ characteristic 値を 1 つでも read 成功」。uuid32 は `uuid128_to_uuid32` の Base-UUID quirk で 16bit 値が上位に来る（0x180A→0x0A180000）。値・props=2(READ)・descriptor が読めていれば GATT パス成立。選択 B（nRF Connect）では service/char/値はアプリ設定どおりに出る。

## Phase3 — ThreadSanitizer（任意・強く推奨）

GCD(CoreBluetooth) と VM スレッド境界の data race を確認する。fixture を別デバイスで動かしつつ、central 側の Swift dylib を TSan 付きでビルドして scan/connect/read を回し、`pble.cb` queue 上に `mrb_*`/`BLE_push_event` フレームが乗らないこと・race ゼロを確認する。dylib の TSan ビルドは `swift build --sanitize=thread`（ext dir）で行い、picoruby から差し替えてリンクする（手順は別途）。

## トラブルシュート

- **adv は大量に受かるが peripheral が見つからない**: 同一 Mac で peripheral を動かしていないか確認（loopback 不可）。別デバイスで advertise する。
- **adv が 1 件も受からない**: 中央 Mac の Bluetooth 許可を確認（System Settings > Privacy & Security > Bluetooth、ターミナル/実行元アプリを許可）。
- **発見はするが connect 後に進まない**: peripheral が connectable advertising か、char が readable か確認。`debug: true` で FSM 遷移を出せる（`step3_e2e_central.rb` の scan に既に付与済み）。
- **descriptor 値が空**: 一部 descriptor は静的値を持たない。char 値が読めて `:TC_IDLE` に到達していれば GATT パスは成立。
