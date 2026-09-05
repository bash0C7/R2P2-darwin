# iOS Stack-chan操作アプリに発話機能を追加する

日付: 2026-09-05
状態: 実装済み・実機確認済み（2026-09-05）。実装時の追加判断: AVSpeechSynthesizer.writeはゼロ長end markerを複数回配送するためcompletionはsingle-fireガード付き、pitchMultiplier=1.5

## 目的

`examples/ios/stackchan/`（iOS操作アプリ）から、Stack-chan本体のスピーカーで任意のテキストを
しゃべらせる。stackchan-picoruby（PC CLI + daemon）が持つ`say`機能のiOS版。
あわせてTorque on/offグループをUIから外し、代わりにテキストボックス
（デフォルト「ぼくスタックチャン、かわいいよ」）と発話ボタンを置く。

## 前提事実（stackchan-picoruby側の実装から確定済み）

発話は「送信側でTTS→G.711 mu-law音声をBLEで流し込み→デバイスのスピーカーで再生」方式。
デバイスにTTSエンジンはない。プロトコルは以下（ファイル参照はstackchan-picoruby repo）:

- **字幕フレーム**: `"<text:本文>\n"`。UTF-8そのまま。sanitize必須: `,`→`、`、`<`→`＜`、
  `>`→`＞`、CR/LF→半角スペース1個。PicoRubyの`gsub`はマルチバイトで末尾を落とすので
  `each_char`で置換する（`mrbgems/picoruby-stackchan-shared/mrblib/stackchan/ai/frame_text.rb`）。
  字幕は19文字でtruncate（`MAX_CHARS = 19`、デバイス側`SUBTITLE_MAX_CHARS`との契約）。
  読み上げテキスト自体に長さ制限はない
- **音声ストリーム**（半二重、NUS RXへwrite without response）:
  1. `"<A:N>\n"` を書く（N = mu-lawバイト数、10進ASCII）
  2. デバイスは`<A:ready>`を通知するが、PC実装はこれを待たず固定1.5秒sleep
     （`READY_WAIT_S = 1.5`、`pc/stackchan-pico/app/daemon_app.rb`）
  3. 生mu-lawバイト列を**180バイト/回、20ms間隔**で書く（フロー制御なし。
     ペーシングを外すと黙って切り詰められる）
  4. デバイスは`<A:N>`受信から`T = N*1000/8000 + 3000` msの間、RXキューを
     音声としてdrainする。**この窓内に送った他フレームは音声と誤解釈される**
- **音声フォーマット**: 8kHz / mono / G.711 mu-law。音量はエンコード前のデジタルgainで
  調整（PC defaultは0.05、イベント運用実績値は0.175）
- `<A:N>`と音声バイトにACKは返らない

## 本repo側の確定事実

- `vm_call(vm, method, arg)`はargを`$__vm_arg`にString globalとして渡す
  （`bridge/picoruby_bridge.c`。dispatch sourceは固定文字列で、argのソース埋め込みはない）。
  ただし`withCString`のNUL終端渡しなので**生バイナリは不可、ASCII安全な文字列は長さ不問**
- stackchan用build_config（sim/device両方）には`mruby-pack`が既に入っており、
  Rubyで`[hex].pack("H*")`によるC速度のhexデコードが使える
- `app.rb`のBLE書き込みは`RealBleLink#write` →
  `write_value_of_characteristic_without_response`。frame内容を`print`でechoする

## アーキテクチャ（採用: Approach A）

**Swift = 音声生成、Ruby = プロトコル駆動。** bridge・fork・build_configは変更しない。
BLEの所有はこれまでどおりVM内のRealBleLink（「Rubyがロボットを駆動する」構図を保つ）。

```
[TextField + Speakボタン]
        │ ①subtitle(text)                      vm_call経由
        ▼
[app.rb] FrameCodec.encode_text → "<text:…>\n" → BLE
        │
[SpeechSynth.swift] AVSpeechSynthesizer.write → PCM
        → AVAudioConverterで8kHz/mono変換 → gain適用 → Int16化 → mu-lawエンコード → hex文字列
        │ ②speak_audio(hex)                    vm_call経由
        ▼
[app.rb] [hex].pack("H*") → "<A:N>\n" → 1.5s待ち → 180B/20ms送信 → drain窓明け待ち
```

## コンポーネント

### 1. `Sources/SpeechSynth.swift`（新規）

- `SpeechSynth.synthesize(text: String, completion: @escaping (String?) -> Void)`
  非同期でhex文字列（mu-law 8kHz mono）またはnil（失敗）を返す
- 実装: `AVSpeechSynthesizer.write(_:toBufferCallback:)`でPCMバッファを収集
  → `AVAudioConverter`で8kHz/monoへ変換 → gain 0.175を掛けてclamp → Int16化
  → 標準G.711 mu-lawエンコード（手書き、bias 0x84の一般式）→ hex化
- 音声: `AVSpeechSynthesisVoice(language: "ja-JP")`、rateはデフォルト
- `AVSpeechSynthesizer`インスタンスは合成完了まで保持（解放されるとcallbackが止まる）

### 2. `Sources/ContentView.swift`（変更）

- **Torqueグループを削除**（app.rbの`torque`メソッドと`encode_torque`は温存。
  wire仕様のリファレンスであり、削除はこのタスクの要求外）
- **Speechグループを新設**:
  - `TextField`、`@State speakText = "ぼくスタックチャン、かわいいよ"`
  - 「Speak」ボタン。タップで: `speaking = true` → `send("subtitle", speakText)`
    → `SpeechSynth.synthesize` → 成功なら`VMExecutor.shared.call("speak_audio", hex)`
    完了で`speaking = false`／失敗なら出力欄にメッセージ表示して解除
  - デザインは既存パーツと統一: `group("Speech")`ヘルパーで括り、ボタンは`.buttonStyle(.glass)`、
    TextFieldは`.textFieldStyle(.roundedBorder)`等、既存グループと同じ見た目に揃える
  - 発話中はSpeakボタンをdisable（connectと同じsingle-flight。streamingは
    VMスレッドを数秒〜十数秒塞ぐため二重投入を防ぐ）。空テキストはボタンをdisable
- vm_callのserial queueが順序を保証するので、subtitle→speak_audioの順序制御は不要

### 3. `examples/ios/stackchan/app.rb`（変更）

- `FrameCodec::TEXT_MAX_CHARS = 19`、`FrameCodec.sanitize_text(s)`（`each_char`で
  `,<>`全角化・CR/LF→空白）、`FrameCodec.encode_text(s)`（sanitize→19文字truncate→
  `"<text:#{s}>\n"`）
- `FrameCodec.encode_audio_header(n)` → `"<A:#{n}>\n"`
- `Stackchan#subtitle(arg)`: `@ble.write(FrameCodec.encode_text(arg))`
- `Stackchan#speak_audio(hex)`:
  1. `bytes = [hex].pack("H*")`、`n = bytes.bytesize`。`n == 0`なら即return
  2. `@ble.write(FrameCodec.encode_audio_header(n))`
  3. `sleep_ms 1500`（`<A:ready>`は読まない。PC実装と同じ固定待ち）
  4. 180バイトずつ`@ble.write_chunk(bytes[i, 180])`、各回`sleep_ms 20`
  5. drain窓の残りを待つ: `remaining_ms = (n * 1000 / 8000 + 3000) - 1500 - チャンク数*20`。
     正なら`sleep_ms(remaining_ms + 500)`（margin 500ms）。これで窓内に後続フレームが
     音声と誤解釈されるのを防ぐ
  6. 進捗は`print "audio: #{n} bytes sent\n"`程度に留める（バイナリをechoしない）
- `RealBleLink#write_chunk(data)`: `write`と同じ書き込みだが**printしない**
  （バイナリでOutput paneを汚さない）。未接続なら捨てて`:dropped`
  （音声バイト列のpending蓄積は無意味なため）。`BleLink`（host stub）にも同名を足し、
  記録のみ行う
- `sleep_ms`が呼べること（picoruby-machine由来）は実装時にsmokeで確認。
  なければ`sleep 0.02`系へフォールバック

### 4. `examples/ios/stackchan/test_frames.rb`（変更）

host CRubyで走る既存のcodecテストに追加:
- `encode_text`: sanitize（`,<>`・CR/LF）、19文字truncate（マルチバイト）、
  UTF-8がバイト列で温存されること
- `encode_audio_header`: `"<A:1234>\n"`形式
- `speak_audio`のチャンク分割数と各チャンク長（BleLink stubの記録で検証。
  sleepはstub側で無視できる設計にする）

### 5. `examples/ios/stackchan/project.yml`

`Sources/`はディレクトリ指定なのでSpeechSynth.swiftは自動で入る見込み。
`rake ios:stackchan:gen`後にターゲットに含まれることを確認し、必要ならymlへ明記。

## エラー処理

- 合成失敗（voice取得不可等）: Output paneに1行表示、speaking解除。リトライしない
- 未接続時のspeak: 字幕フレームは既存pending経路へ。`speak_audio`は何も書かずに早期return
  （headerだけがpendingに残ると、後の接続時にデバイスが音声なしのdrain窓へ入るため）。
  Output paneの既存メッセージで状況が見える
- vm_call中の例外はbridgeの既存安全網（backtraceがOutput paneへ）に任せる

## スコープ外（YAGNI）

- gain / rate / voiceのUI調整（定数で固定）
- `<A:ready>` / `<A:done>`通知の受信（PC実装すらreadyを待たない。時間ベースで足りる）
- iPhoneローカルでの同時再生（しゃべるのはStack-chan本体のみ）
- chat（AI応答）機能

## テスト計画

1. `rake smoke`（host。test_frames.rbの追加分を含む）
2. `rake ios:stackchan:device:check`（署名不要ビルド）
3. 実機Stack-chan + iPhoneでの発話確認（**user実施**。デフォルト文言と任意文言、
   日本語字幕の表示、音声の途切れ有無）。実機確認完了までは「動いた」と書かない

## 変更ファイル一覧

| ファイル | 種別 |
|---|---|
| `examples/ios/stackchan/Sources/SpeechSynth.swift` | 新規 |
| `examples/ios/stackchan/Sources/ContentView.swift` | 変更（Torque撤去・Speech追加） |
| `examples/ios/stackchan/app.rb` | 変更（encode_text / speak_audio / write_chunk） |
| `examples/ios/stackchan/test_frames.rb` | 変更（codecテスト追加） |
| `examples/ios/stackchan/project.yml` | 必要時のみ |

bridge / build_config / fork（picoruby）/ vendorは変更しない。
