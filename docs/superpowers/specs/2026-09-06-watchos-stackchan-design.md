# watchOS Stack-chan Controller — Design Spec

Date: 2026-09-06
Status: Design approved (brainstorming complete; pending spec review → plan)

## Goal

`examples/watchos/stackchan/` として追加する、Apple Watch単体でStack-chanを操作する
PicoRuby駆動アプリ。`examples/ios/stackchan/` のsubsetで、操作は3つに絞る。

- **顔**: たのしそうな顔2パターン（`smile` ⇄ `joy`）をタップで切替
- **LED**: タップでランダム色のblink開始、もう一度のタップで停止
- **首**: 1タップで左→右→上→ニュートラルの一連のシーケンスを自動実行

iPhoneのcompanionは持たない。watch上のPicoRuby VMがpicoruby-bleのcentralを直接駆動し、
Stack-chanのNordic UART Service（NUS）へASCIIフレームを書く。

speak機能（TTS / 字幕 / mu-law音声ストリーミング）とtorqueはsubsetの対象外。

## Non-goals

- iPhone companion app、WatchConnectivity経由の中継
- speak / subtitle / torque / touchイベント受信
- 任意の顔・任意のLED色・任意の首角度を選ぶUI（iOS版が担う）
- 既存の `examples/watchos/led-toggle/` の置き換え（そのまま温存する）

## 前提となる制約

### watchOSに`CBPeripheralManager`が無い

watchOS SDKの `CBPeripheralManager.h` は初期化子を `API_UNAVAILABLE(watchos, tvos)` と
宣言している（`WatchOS26.5.sdk` で確認）。picoruby-bleのDarwin portは
central（`PicoBLECentral.swift`）とperipheral（`PicoBLEPeripheral.swift`）を1つの
Swift package `PicoBLEDarwin` に同居させているため、packageをそのままwatchOS向けに
コンパイルすると失敗する。

本設計で必要なのはcentralのみ。したがってfork側でperipheralをwatchOSからコンパイル対象外にする。
`CBCentralManager` 自体はwatchOSで利用可能なので、Apple WatchからStack-chanへ直接BLEで
繋ぐことは成立する。

### watchOSのスタックサイズ

`DispatchQueue` の既定スタックはwatchOSでは非常に小さく、mruby VMの初期化でオーバーフローする。
`examples/watchos/led-toggle/Sources/VMExecutor.swift` は専用の `Thread` に
`stackSize = 4 * 1024 * 1024` を与えてこれを回避している。本exampleも同じ骨格を使う。

### watchOSのfork/exec禁止

mruby-ioのPOSIX HALは `IO.popen` でspawnするためwatchOSで使えない。既存の
`build_config/r2p2-picoruby-watchos-*.rb` は `hal-io-darwin` gemでこれを差し替えている。
新設のstackchan向けwatchOS configも同じgemを含める。

## Architecture

```
Apple Watch
┌──────────────────────────────────────────────┐
│ ContentView (SwiftUI, List, 4 rows)          │
│        │ VMExecutor.call(method, arg)        │
│        ▼                                     │
│ VMThread (dedicated Thread, 4MB stack)       │
│   vm_open / vm_call / 1秒周期のtick          │
│        │ picoruby_bridge.c                   │
│        ▼                                     │
│ PicoRuby VM ── app.rb                        │
│   FrameCodec / RealBleLink / Stackchan       │
│        │ picoruby-ble (Rubyレイヤ)           │
│        ▼                                     │
│ PicoBLEDarwin.framework (central only)       │
│        │ CoreBluetooth                       │
└────────┼─────────────────────────────────────┘
         ▼  BLE / NUS RX characteristic
    Stack-chan
```

VMを触るのは `VMThread` の `workQueue` ただ一つ。SwiftUIレイヤはクロージャをpostするだけで
`vm_*` を直接呼ばない。iOS版stackchanと同じ規律。

## Directory Layout

新設するもの:

```
examples/watchos/stackchan/
├── project.yml                              → WatchStackchan.xcodeproj
├── app.rb                                    iOS版stackchanのsubset
├── test_frames.rb                            host CRubyでのフレーム検証
├── README.md
├── README_jp.md
└── Sources/
    ├── App.swift
    ├── ContentView.swift
    ├── VMExecutor.swift
    └── WatchStackchan-Bridging-Header.h

build_config/
├── r2p2-picoruby-watchos-stackchan-sim.rb
└── r2p2-picoruby-watchos-stackchan-device.rb
```

`Vendor/lib/libmruby.a` と `Vendor/include/` はrakeが生成する（gitに入れない）。

変更するもの:

- `Rakefile` — `namespace :watchos` に `:stackchan` を追加
- `build_config/recompile_arm64_32.rb` — 決め打ちのconfig名とbuild名を引数化
- `README.md` / `README_jp.md`（repo直下）— example一覧とtask一覧に追記

## fork（`bash0C7/picoruby` の `port-darwin`）への変更

編集はclone `~/dev/src/github.com/bash0C7/picoruby` の `port-darwin` worktreeで行い、
`port-darwin` へ直接commitする。pushはuser承認を得てから。検証中は未pushのまま
`PICORUBY_REPO=/Users/bash/dev/src/github.com/bash0C7/picoruby PICORUBY_REF=port-darwin rake refresh`
で本repoへ流し込む。

対象は `mrbgems/picoruby-ble/ports/darwin/ext/` の3ファイル。

### 1. `Package.swift`

`platforms` に `.watchOS(.v6)` を追加する。既存の `.macOS(.v11)` / `.iOS(.v13)` はそのまま。

watchOS SDKの `CBCentralManager.h` にはクラスにも初期化子にも `API_UNAVAILABLE(watchos)` が
無く、centralロールはwatchOSで使えることを確認済み（`WatchOS26.5.sdk`）。アプリの
deployment targetは `project.yml` で `watchOS 26.0` を指定するので、package側の下限が
`.v6` であることは制約にならない。

### 2. `Sources/PicoBLEDarwin/PicoBLEPeripheral.swift`

ファイル全体を `#if !os(watchOS)` … `#endif` で囲う。`PBLEPeripheral` クラスは
watchOS向けビルドから消える。

### 3. `Sources/PicoBLEDarwin/PicoBLEExports.swift`

`pble_peripheral_*` の各export（`pble_peripheral_init` / `_power_on` / `_power_off` /
`_advertise` / `_stop_advertise` / `_notify` / `_request_can_send_now`）を、watchOSでは
`PBLEPeripheral` を呼ばないno-op stubに差し替える。

これらのシンボルはgemのC側 `ble_peripheral.c` がexternとして参照しており、
`ble_peripheral.c` はwatchOSでもarchiveに入る。exportごと消すとアプリのリンクが
未解決シンボルで壊れるため、stubは必須。

centralのexport（`pble_central_init` / `pble_scan` / `pble_connect` / `pble_write_value` など）と
`pble_drain_one` は変更しない。

**この変更はiOS / macOS向けビルドの挙動を一切変えない。** `#if !os(watchOS)` の外側は
従来どおりコンパイルされる。既存のiOS stackchan / virtual-peripheral exampleの
リグレッションが無いことを、`rake ios:stackchan:device:check` と
`rake ios:vperiph:*` で確認する。

## build_config

`r2p2-picoruby-watchos-stackchan-sim.rb` / `-device.rb` は、既存の
`r2p2-picoruby-watchos-{sim,device}.rb` を土台に、
`r2p2-picoruby-ios-stackchan-{sim,device}.rb` のBLE部分を合流させる。

土台（既存watchOS configから引き継ぐ）:

- `watchsimulator` / `watchos` SDK、`-mwatchos-version-min`（`WATCHOS_MIN`、既定 `11.0`）
- device側は `-arch arm64_32`
- `conf.linker.libraries.delete("m")`
- `cc.defines`: `MRB_TICK_UNIT=4` / `MRB_TIMESLICE_TICK_COUNT=3` / `PICORB_ALLOC_ALIGN=8` /
  `PICORB_ALLOC_ESTALLOC` / `PICORB_PLATFORM_POSIX` / `PICORB_PLATFORM_DARWIN` /
  `MRB_INT64` / `MRB_NO_BOXING` / `MRB_UTF8_STRING`
- `conf.ports :darwin, :posix`
- `conf.gem core: "picoruby-machine"`
- `conf.gem core: "hal-io-darwin"`（watchOSのfork/exec禁止への対応）

BLE部分（iOS stackchan configから持ち込む）:

- `MRuby::Build#darwin?` のfalse fallback（`method_defined?` ガード付き）
- `mruby-string-ext` / `mruby-pack` / `mruby-sprintf`（picoruby-bleのmrblibが
  `Array#pack` / `String#<<` / `sprintf` を使う）
- `conf.cc.include_paths << "#{ble_gemdir}/ports/darwin/ext"`
- `conf.gem ble_gemdir`（`PICORUBY_BLE_GEMDIR` でoverride可）
- **picoruby-mbedtls / picoruby-rng の依存は外さない。** `ble.rb` がbootで
  `require 'mbedtls'` し、GATT database hashが `MbedTLS::CMAC` を使う

追加:

- `mruby-random` — `led_toggle` のランダム色選択に `rand` が要る。既存configのgem集合には
  含まれていないので明示的に足す（`vendor/picoruby/mrbgems/picoruby-mruby/lib/mruby/mrbgems/mruby-random`）

build名は `watchos-stackchan-sim` / `watchos-stackchan-device`。

## `app.rb`

`examples/ios/stackchan/app.rb` から出発し、subsetに削る。

### `FrameCodec` — 残すもの

- `SIDE_TO_CHAR` / `MODE_TO_CHAR` / `FACE_INDICES` / `LED_COLORS` の各テーブル
- `ACK_OK` / `ACK_ERROR`
- `encode_pairs` / `encode_face` / `encode_led` / `encode_head` / `parse_ack`

**左右の反転（`"left" => "R"` / `"right" => "L"`）はファームウェアの配線に合わせた
load-bearingな仕様であり、直さない。** ワイヤ上のフレーム形式も同じ。

### `FrameCodec` — 落とすもの

`encode_torque` / `sanitize_text` / `truncate_chars` / `encode_text` /
`encode_audio_header` / `chunk_audio_hex` / `parse_touch` と、それらの定数
（`TEXT_MAX_CHARS` / `AUDIO_CHUNK_BYTES` / `TOUCH_PREFIX`）。

### BLEトランスポート層 — iOS版と同一

`NUS_*` 定数群 / `HEX_DIGITS` / `STACKCHAN_NAME` / `require "ble"` のLoadErrorガード /
`BLE_AVAILABLE` / `HAS_SLEEP_MS` / `msleep` / `BleLink`（記録stub） /
`StackchanCentral` / `RealBleLink` をそのまま持ち込む。

`BleLink#write_chunk` と `RealBleLink#write_chunk` はaudio専用なので落とす。

`BLE_AVAILABLE` の判定はホストCRuby（`test_frames.rb`）で `BleLink` stubに落ちる経路を
維持する。これがあるおかげで無線なしにフレームエンコーダを検証できる。

### dispatcher `Stackchan`

状態を2つ持つ。

```ruby
@face_state = "smile"   # "smile" | "joy"
@led_on     = false
```

公開メソッドは5つ。すべて `vm_call(method, arg)` から1つのStringを受け取る。

| メソッド | 挙動 | printする文字列 |
|---|---|---|
| `connect(arg)` | iOS版と同一。scan → connect → discover → NUS RXのvalue handleをbind | ステータス行（`Connected; RX value_handle bound` など） |
| `tick(arg)` | BLEイベントポンプ。Swiftが1秒周期でpost | 通常は空 |
| `face_toggle(arg)` | `@face_state` を `"smile"` ⇄ `"joy"` で反転し、`encode_face` のフレームを送る | 反転後の顔名（`smile` / `joy`） |
| `led_toggle(arg)` | `@led_on` を反転。ONなら `LED_RANDOM_COLORS` から `rand` で1色選び `encode_led(color:, side: "both", mode: "blink")`。OFFなら `encode_led(color: "off", side: "both", mode: "off")` | `on:<color>` / `off` |
| `head_sweep(arg)` | 4フレームを順に送る。各フレームの後に `msleep(600)` | `swept` |

`LED_RANDOM_COLORS = ["red", "green", "blue", "yellow", "cyan", "magenta"]`
（`white` と `off` は「ランダムに光る」の意図から外れるので除く）。

`head_sweep` のシーケンス:

1. `encode_head(yaw_left: 60, time_ms: 500)`
2. `encode_head(yaw_right: 60, time_ms: 500)`
3. `encode_head(pitch_up: 40, time_ms: 500)`
4. `encode_head(yaw_left: 0, pitch_up: 0, time_ms: 400)` — ニュートラル復帰

合計で約2.5秒、VMスレッドを占有する。UI側でsingle-flightにする（下記）。

`$app = Stackchan.new` でboot時にインスタンス化するのはiOS版と同じ。

## Swift層

### `VMExecutor.swift`

`examples/watchos/led-toggle/Sources/VMExecutor.swift` の骨格
（`VMThread: Thread` + `stackSize = 4MB` + `workQueue`）に、
`examples/ios/stackchan/Sources/VMExecutor.swift` のAPIを移植する。

```swift
func start(bootSource: String, onResult: @escaping (String) -> Void)
func call(_ method: String, _ arg: String, onResult: @escaping (String) -> Void)
```

- `call` は `workQueue` にpostし、captured outputをmain queueで返す
- VM未initialization時は `"(VM not ready)"` をmain queueで返す（呼び出し側が
  `@State` を触るため、main以外で呼んではならない）
- VMがopenした直後に1秒周期のtickタイマーを `workQueue` 上に張る。tick出力は
  空でなければ `NSLog` にのみ出す
- 各 `call` の結果も `NSLog` にミラーする（実機のログを `rake` 側から読むため）

### `ContentView.swift`

`List` に4行 + ステータス1行。

```
┌─────────────────┐
│ ⬤ Connect       │  connected/failed/scanning で色が変わる、scan中はdisabled
│ 😊  Face        │  タップで 😊 ⇄ 😆
│ ⬤  LED         │  ONは選ばれた色の丸／OFFはグレーの丸
│ ↻  ぐるっと     │  実行中はdisabled
│ connected       │  1行ステータス（.caption）
└─────────────────┘
```

`@State`:

- `output: String` — 直近のVM出力（ステータス行の導出元）
- `connected: Bool` / `connectFailed: Bool` / `busy: Bool` — Connectの状態機械
- `faceState: String` — `"smile"` / `"joy"`。`face_toggle` のprintから更新
- `ledColor: String?` — `nil` がOFF。`led_toggle` のprint（`on:cyan`）をparseして更新
- `sweeping: Bool` — `head_sweep` のsingle-flightガード

single-flightにするのは `connect`（最大30秒ブロックする）と `head_sweep`（約2.5秒
ブロックする）の2つ。連打で30秒のscanが積み上がるのを防ぐ。

iOS版のOutputペインはwatchには置かない。画面が狭く、VM出力は `NSLog` から読めるため。

boot時は `Bundle.main.url(forResource: "app", withExtension: "rb")` を読んで
`VMExecutor.shared.start` に渡す。led-toggle / iOS stackchanと同じ。

### `App.swift` / Bridging Header

led-toggle版をそのまま（名前だけ `WatchStackchanApp` に変える）。
Bridging Headerは `#include "picoruby_bridge.h"` の1行。

## `project.yml`

`examples/watchos/led-toggle/project.yml` を土台に、
`examples/ios/stackchan/project.yml` のBLE部分を合流させる。

led-toggleから引き継ぐwatchOS固有設定:

- `deploymentTarget: watchOS: "26.0"`
- `INFOPLIST_KEY_WKApplication: "YES"` / `INFOPLIST_KEY_WKWatchOnly: "YES"`
- `TARGETED_DEVICE_FAMILY: "4"`
- `GCC_PREPROCESSOR_DEFINITIONS` に `HEAP_SIZE=2097152`

stackchanから持ち込むBLE設定:

- `packages.PicoBLEDarwin.path: ../../../vendor/picoruby/mrbgems/picoruby-ble/ports/darwin/ext`
- `dependencies: - package: PicoBLEDarwin, embed: true`（dylibをアプリの `Frameworks/` に置いて
  dyldが `pble_*` を解決できるようにする）
- `OTHER_LDFLAGS: -lmruby -framework Security`（mbedtls / rngのDarwin portが使う
  `SecRandomCopyBytes` の解決）
- `INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription`

新規:

- `PRODUCT_BUNDLE_IDENTIFIER: com.bash0c7.picoruby.WatchStackchan`
- `SWIFT_OBJC_BRIDGING_HEADER: Sources/WatchStackchan-Bridging-Header.h`
- `HEADER_SEARCH_PATHS` の `build/watchos-sim/include` / `build/watchos-device/include` を
  `build/watchos-stackchan-sim/include` / `build/watchos-stackchan-device/include` に差し替え

`DEVELOPMENT_TEAM: SM5792D355` / `CODE_SIGN_STYLE: Automatic` は既存exampleと同じ。

### define parity

`project.yml` の `GCC_PREPROCESSOR_DEFINITIONS` と build_config の `cc.defines` は
一致していなければならない。不一致は `sizeof(mrb_state)` に効き、bridgeとlibの間の
メモリ破壊になる。`MRB_BASELINE_PROFILE=1` はconfigに書かれず `picoruby-mruby` が
build-wideに足すので、`project.yml` 側が追従する（led-toggleと同じ扱い）。

確認は `cd vendor/picoruby && rake -v` のcompile commandから `-D` を抽出して突合する。

## `recompile_arm64_32.rb` の引数化

現状のスクリプトは以下を決め打ちしている。

- `BUILD_DIR = build/watchos-device`
- `CONFIG_RB = build_config/r2p2-picoruby-watchos-device.rb`

これを引数（またはENV）で受け取れるようにし、`watchos:led:device:lib` は
`watchos-device` + `r2p2-picoruby-watchos-device.rb` を、
`watchos:stackchan:device:lib` は `watchos-stackchan-device` +
`r2p2-picoruby-watchos-stackchan-device.rb` を渡す。

**cc.definesをconfigファイルから読み取る仕組みと、`watchos_min` をconfigから
parseする仕組みは維持する。** これは再コンパイルするobjectがdefineでdriftしないための
単一ソースであり、崩すとサイレントなオンデバイス破壊になる。

## Rakefile

`namespace :watchos` に `:stackchan` を `:led` と同形で追加する。

```
watchos:stackchan:lib             watchos-stackchan-sim のlibmruby.a を Vendor へstage
watchos:stackchan:gen             xcodegen generate
watchos:stackchan:build           Simulator向けbuild
watchos:stackchan:run             Simulatorへinstall + launch
watchos:stackchan:all             lib → gen → build → run
watchos:stackchan:device:lib      watchos-stackchan-device をbuild + arm64_32 recompile + stage
watchos:stackchan:device:build    署名して接続中のApple Watch向けbuild
watchos:stackchan:device:check    署名なしのgeneric deviceリンク（実機不要）
watchos:stackchan:device:run      実機へinstall + launch
watchos:stackchan:device:all      lib → gen → build → run
```

既存の `sim_build` / `device_build` / `device_check_build` / `built_app` /
`sim_install_launch` / `device_install_launch` ヘルパをそのまま使う。
`archs: "arm64_32"` / `platform: "watchOS"` はled版と同じ。

device系rakeをtmux / subagentから回すときは、command側で `LANG` と `RBENV_VERSION` を
明示する。端末名に非ASCIIがあると `devicectl` / `xcodebuild -showdestinations` の出力に
対するRakefileのregexが `invalid byte sequence` で落ちる。

## `test_frames.rb`

ホストCRubyで `app.rb` を読み込み（`BLE_AVAILABLE` がfalseになり `BleLink` stubが使われる）、
`Stackchan` の各メソッドが記録したフレームがPC CLIのcodecとbyte単位で一致することを検証する。

`examples/ios/stackchan/test_frames.rb` の構成を踏襲し、subsetに合わせて検証項目を絞る。

- `face_toggle` を2回呼ぶと `<F:1>\n` → `<F:2>\n`（smile → joy）が出る
- `face_toggle` を4回呼ぶと smile → joy → smile → joy と巡回する
- `led_toggle` のON時のフレームが `<L:1,R:...,G:...,B:...,S:B,M:b>\n` の形で、
  RGBが `LED_RANDOM_COLORS` のいずれかの値と一致する
- `led_toggle` のOFF時が `<L:1,R:0,G:0,B:0,S:B,M:o>\n`
- `led_toggle` を2回呼ぶとON → OFFになる
- `head_sweep` が4フレームを順に出し、最後が `<YL:0,PU:0,T:400>\n`
- 左右反転（`"left"` → `YL`、`"right"` → `YR`）が保たれている

`rake smoke` には組み込まない。`rake smoke` は `bridge/smoke_test.c` を走らせるC層のテストで、
Rubyのフレーム検証は別concern。iOS版stackchanと同じく、READMEに
`ruby examples/watchos/stackchan/test_frames.rb` の手順を書いて単独実行できる形にする。

## 検証の順序と完了の線引き

1. `ruby examples/watchos/stackchan/test_frames.rb` — ホストCRuby、フレームのbyte一致
2. `rake watchos:stackchan:lib` → `:gen` → `:build` → `:run` — watchOS Simulator。
   BLEは繋がらない（scanがタイムアウトする）が、VMのbootとUIの操作は確認できる
3. `rake watchos:stackchan:device:lib` → `:device:check` — arm64_32でのリンク（署名不要、実機不要）
4. 既存exampleのリグレッション確認 — `rake smoke`、`rake ios:stackchan:device:check`、
   `rake watchos:led:device:check`
5. 実機Apple Watch + 実Stack-chan — `rake watchos:stackchan:device:all`

**実機の挙動は実機で実証するまで「動いた」と書かない。** 1〜4が通った段階では
「Simulatorまで通った、実機未確認」と報告する。

merge は user が実機確認の完了を明言してから。それまでmergeの提案自体をしない。

## 未解決のリスク

実装前に読み切れていないものを明示する。いずれも実装中に判明したら、回避せず対処する。

### 1. arm64_32でのmbedtls / rngのビルド

`recompile_arm64_32.rb` は `build/<target>` 配下のarm64 objectを総なめして `.d` ファイルから
ソースを引き当て、arm64_32で再コンパイルする作りなので、mbedtlsのCソースも同じ経路に乗る見込み。
ただし実際に通るかは未検証。アーキ依存のasmやintrinsicがあれば個別対処が要る。

失敗した場合の対処: 失敗したソースを特定し、mbedtlsのconfigでその機能を無効化するか、
fork側のdarwin portでポータブルな実装に差し替える。**古いSHAへのpinで逃げない。**

### 2. `HEAP_SIZE=2097152` の十分性

led-toggleは2MBで足りているが、picoruby-ble + mbedtls + string-ext/pack/sprintf/random が
乗ったVMで足りるかは未検証。boot時にOOMするなら広げる。Apple Watchの物理メモリは
Series 8で1GBあるので、4〜8MBへの引き上げは現実的。

### 3. 30秒スキャン中のwatch appのサスペンド

watchOSは手首を下ろすとアプリを積極的にサスペンドする。`connect` は最大30秒
VMスレッドをブロックするので、その間にサスペンドされるとscanが完了しない可能性がある。

対処の候補（実機で挙動を見てから選ぶ）:
- `scan(timeout_ms:)` を10秒程度に短くし、UIから再試行しやすくする
- `WKExtendedRuntimeSession` でセッション中のサスペンドを抑止する

### 4. watchOSでのBluetooth権限プロンプト

`NSBluetoothAlwaysUsageDescription` をInfo.plistに入れるが、watchOSでのプロンプトの
出方（watch上に出るのかiPhone側に出るのか）は実機で確認する。

## 不変条件（壊さないもの）

CLAUDE.mdに記載のものを本exampleにも適用する。

- **picoruby-bleの `picoruby-mbedtls` / `picoruby-rng` 依存を外さない。** `ble.rb` がbootで
  `require 'mbedtls'` し、GATT database hashが `MbedTLS::CMAC` を使う
- **example固有のgemはexample専用build_configに置く。** BLEとmruby-randomは
  `r2p2-picoruby-watchos-stackchan-*.rb` にのみ入れ、既存の
  `r2p2-picoruby-watchos-*.rb` には足さない（led-toggleのリンクが壊れる）
- **mruby task HALの6 entryは `bridge/task_hal_ios.c` の所有物。** darwin portの `hal.c` に
  定義しない
- **build_configのdefineを変えたら再build前に `rm -rf build/<target>`。** compile ruleは
  `.c` のmtimeしか見ないのでstaleな `.o` が再利用され、変更が黙って効かない
- **`vendor/picoruby` は生成物。commitしない**
- **`port-darwin` はupstream masterに対してbehind 0を保つ**
