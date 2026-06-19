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

### 選択 B: iOS デバイスのアプリ（nRF Connect / LightBlue）

- アプリで GATT server を構成し、**readable な characteristic を 1 つ**（できれば descriptor も）持つ service を作って advertise する。**local name を `PBLE-TEST`** にする（別名にするなら下の central スクリプトの `name_include?` 文字列を合わせる）。
- アプリは**フォアグラウンド維持**（iOS は背景化すると local name を広告しない）。
- char 値はアプリで設定した値が読めれば OK（E2E スクリプトの PASS 判定は固定値 `PBLE-TEST-MFR` を見るので、選択 B では値一致でなく「ツリーが構築され `:TC_IDLE` に到達」を確認する。スクリプトの判定文字列を実機の値に合わせてもよい）。

## central を走らせる（中央 Mac、このリポジトリで）

```sh
build-ble/host/bin/picoruby \
  /path/to/picoruby-ble-apple_silicon-port/mrbgems/picoruby-ble/ports/darwin/test/step3_e2e_central.rb
```
スクリプトは scan(15s) →`PBLE-TEST` 発見で connect → discover → read を 1 つの poll loop で駆動し、ツリーを表示する。

期待出力（選択 A の場合）:
```
[central] found PBLE-TEST (rssi=...); connecting
[central] discovery done; state=TC_OFF services=1
  svc uuid32=0x0A180000 1..N
    char uuid32=0x292A0000 vh=3 props=2 value="PBLE-TEST-MFR"
      desc uuid32=0x01290000 handle=4 value="pble-demo-desc"
E2E PASS: characteristic value read end-to-end
```
（uuid32 は `uuid128_to_uuid32` の Base-UUID quirk により 16bit 値が上位に来る。値・props=2(READ)・descriptor 値が読めれば成功。）

## Phase3 — ThreadSanitizer（任意・強く推奨）

GCD(CoreBluetooth) と VM スレッド境界の data race を確認する。fixture を別デバイスで動かしつつ、central 側の Swift dylib を TSan 付きでビルドして scan/connect/read を回し、`pble.cb` queue 上に `mrb_*`/`BLE_push_event` フレームが乗らないこと・race ゼロを確認する。dylib の TSan ビルドは `swift build --sanitize=thread`（ext dir）で行い、picoruby から差し替えてリンクする（手順は別途）。

## トラブルシュート

- **adv は大量に受かるが peripheral が見つからない**: 同一 Mac で peripheral を動かしていないか確認（loopback 不可）。別デバイスで advertise する。
- **adv が 1 件も受からない**: 中央 Mac の Bluetooth 許可を確認（System Settings > Privacy & Security > Bluetooth、ターミナル/実行元アプリを許可）。
- **発見はするが connect 後に進まない**: peripheral が connectable advertising か、char が readable か確認。`debug: true` で FSM 遷移を出せる（`step3_e2e_central.rb` の scan に既に付与済み）。
- **descriptor 値が空**: 一部 descriptor は静的値を持たない。char 値が読めて `:TC_IDLE` に到達していれば GATT パスは成立。
