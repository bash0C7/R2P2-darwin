# iOS Stack-chan発話機能 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** iOS Stack-chan操作アプリから任意テキストをTTS→G.711 mu-law化してBLEで流し込み、Stack-chan本体のスピーカーでしゃべらせる。

**Architecture:** Swift（`SpeechSynth.swift`新規）がAVSpeechSynthesizerでPCMを生成し8kHz/mono/mu-law→hex文字列化。既存vm_call経由でapp.rbへ渡し、Ruby側が字幕フレームと音声ストリーム（`<A:N>`→1.5秒待ち→180バイト/20ms→drain窓明け待ち）をRealBleLinkで駆動する。UIはTorqueグループを撤去しSpeechグループ（TextField+Speakボタン）を新設。

**Tech Stack:** SwiftUI (iOS 26, Liquid Glass) / AVFoundation / PicoRuby (mruby-pack, picoruby-ble Darwin port)

**Spec:** `docs/superpowers/specs/2026-09-05-stackchan-ios-speak-design.md`

## Global Constraints

- bridge / build_config / fork（picoruby）/ vendorは変更しない
- `vendor/picoruby`にcommitしない。ローカルcommitのみ（pushはuser承認）
- UIは既存パーツと同じ流儀: `group()`ヘルパー、`.buttonStyle(.glass)`、`TextField`は`.textFieldStyle(.roundedBorder)`
- `MRB_UTF8_STRING`が定義されたVMなので、**バイナリ文字列をchar-basedの`String#[]`でsliceしない**。バイナリの分割はhex空間（ASCII）で行う
- 縮小VM（prism）は`defined?`キーワード非対応。存在probeは参照+rescueで書く（app.rbの`BLE_AVAILABLE`と同じ流儀）
- PicoRubyの`gsub`はマルチバイト末尾を落とす。文字置換は`each_char`で書く
- ワイヤ仕様の定数はstackchan-picoruby実装と一致させる: chunk=180バイト、pace=20ms、ready待ち=1500ms固定、drain窓=`N*1000/8000+3000`ms、字幕19文字、gain=0.175、8kHz/mono/G.711 mu-law
- テスト実行: `ruby examples/ios/stackchan/test_frames.rb`（host CRuby）。`rake smoke`はこのテストを含まない
- コミットメッセージ末尾に既定のCo-Authored-By / Claude-Sessionトレーラを付ける

---

### Task 1: app.rb — 字幕codec・音声チャンク分割・speakディスパッチ

**Files:**
- Modify: `examples/ios/stackchan/app.rb`
- Test: `examples/ios/stackchan/test_frames.rb`

**Interfaces:**
- Consumes: 既存の`FrameCodec.encode_pairs` / `BleLink`（host stub, `@sent`記録）/ `RealBleLink`（`@ble`, `@rx_value_handle`, `connected?`）
- Produces: `FrameCodec.encode_text(s) -> String`、`FrameCodec.encode_audio_header(n) -> String`、`FrameCodec.chunk_audio_hex(hex) -> Array<String>`、`Stackchan#subtitle(arg)`、`Stackchan#speak_audio(hex)`（vm_callメソッド名`"subtitle"` / `"speak_audio"`としてTask 3のSwiftが呼ぶ）

- [ ] **Step 1: 失敗するテストを書く**

`examples/ios/stackchan/test_frames.rb`の`# Parse helpers.`ブロックの直前に追加:

```ruby
# Subtitle / audio codec (speak feature).
expect("encode_text plain", FrameCodec.encode_text("こんにちは"), "<text:こんにちは>\n")
# Frame delimiters are widened; CR/LF become a single space.
expect("encode_text sanitize", FrameCodec.encode_text("a,b<c>d\ne"), "<text:a、b＜c＞d e>\n")
# 19-char cap (multibyte-safe), mirroring the device's SUBTITLE_MAX_CHARS.
expect("encode_text truncate", FrameCodec.encode_text("あ" * 25),
       "<text:" + "あ" * 19 + ">\n")
expect("encode_audio_header", FrameCodec.encode_audio_header(1234), "<A:1234>\n")

# chunk_audio_hex slices in hex space (ASCII) and packs per chunk, so binary
# mu-law never meets char-based String#[] (MRB_UTF8_STRING VM).
hex = "00112233" * 100   # 400 bytes of audio
chunks = FrameCodec.chunk_audio_hex(hex)
expect("chunk count", chunks.length, 3)
expect("chunk sizes", chunks.map { |c| c.bytesize }, [180, 180, 40])
expect("chunk head bytes", chunks[0][0, 4].bytes, [0x00, 0x11, 0x22, 0x33])

$app.subtitle("やあ,ねえ")
expect("subtitle frame", last_frame, "<text:やあ、ねえ>\n")

# Not connected (BleLink stub): speak_audio must write NOTHING (an orphan
# <A:N> header would trap the device in an audio drain window later).
sent_before = $app.ble.sent.length
$app.speak_audio("00112233")
expect("speak_audio not connected writes nothing",
       $app.ble.sent.length, sent_before)
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin/examples/ios/stackchan && ruby test_frames.rb`
Expected: `undefined method 'encode_text'`（NoMethodErrorで落ちる）

- [ ] **Step 3: 最小実装**

`examples/ios/stackchan/app.rb`へ以下を追加。

(a) `FrameCodec`モジュール内（`encode_torque`の後ろ）:

```ruby
  # ---- Speak feature: subtitle + audio codec --------------------------------
  # Mirrors stackchan-picoruby's frame_text.rb / daemon_app.rb wire contract.

  TEXT_MAX_CHARS = 19       # device SUBTITLE_MAX_CHARS; display-only cap
  AUDIO_CHUNK_BYTES = 180   # BLE write-without-response payload per 20ms

  # Frame delimiters would corrupt the <text:...> frame; widen them. CR/LF
  # become a single space. each_char (not gsub): PicoRuby's gsub drops
  # trailing multibyte chars.
  def self.sanitize_text(s)
    out = ""
    prev_space = false
    s.each_char do |c|
      if c == "\r" || c == "\n"
        out += " " unless prev_space
        prev_space = true
        next
      end
      prev_space = false
      out += case c
             when "," then "、"
             when "<" then "＜"
             when ">" then "＞"
             else c
             end
    end
    out
  end

  # Multibyte-safe truncation via each_char (String#[] would need char
  # semantics we don't want to lean on across CRuby / the reduced VM).
  def self.truncate_chars(s, max)
    out = ""
    n = 0
    s.each_char do |c|
      break if n >= max
      out += c
      n += 1
    end
    out
  end

  def self.encode_text(s)
    "<text:" + truncate_chars(sanitize_text(s), TEXT_MAX_CHARS) + ">\n"
  end

  def self.encode_audio_header(nbytes)
    "<A:#{nbytes}>\n"
  end

  # hex -> array of binary chunks, AUDIO_CHUNK_BYTES each (last one shorter).
  # Slice the ASCII hex (char == byte even under MRB_UTF8_STRING), then pack
  # each slice, so char-based String#[] never touches binary data.
  def self.chunk_audio_hex(hex)
    chunks = []
    step = AUDIO_CHUNK_BYTES * 2
    i = 0
    while i < hex.length
      chunks << [hex[i, step]].pack("H*")
      i += step
    end
    chunks
  end
```

(b) `BleLink`（host stub）に`write_chunk`を追加（`write`の後ろ）:

```ruby
  # Audio chunks: record without echoing (binary would trash the Output pane).
  def write_chunk(data)
    @sent << data
    :ok
  end
```

(c) `RealBleLink`に`write_chunk`を追加（`write`の後ろ、`if BLE_AVAILABLE`ブロック内）:

```ruby
    # Audio chunk write: same radio path as write, but no print (binary) and
    # no pending queue (stale audio bytes are useless after the fact).
    def write_chunk(data)
      return :dropped unless connected?
      @ble.write_value_of_characteristic_without_response(
        @ble.conn_handle, @rx_value_handle, data
      )
      :ok
    end
```

(d) トップレベル（`BLE_AVAILABLE`定義の後ろ）にsleepシム:

```ruby
# sleep_ms comes from picoruby-machine in the device VM; host CRuby has only
# sleep. Probe by calling (the reduced VM lacks the defined? keyword).
HAS_SLEEP_MS =
  begin
    sleep_ms(0)
    true
  rescue NameError, NoMethodError
    false
  end

def msleep(ms)
  if HAS_SLEEP_MS
    sleep_ms(ms)
  else
    sleep(ms / 1000.0)
  end
end
```

(e) `Stackchan`クラスに追加（`torque`の後ろ）:

```ruby
  # Audio streaming timing (stackchan-picoruby daemon_app.rb contract).
  READY_WAIT_MS = 1500    # fixed wait instead of reading <A:ready>
  CHUNK_PACE_MS = 20      # no flow control; unpaced writes get silently cut
  DRAIN_MARGIN_MS = 500

  # arg: subtitle text (UTF-8). Sanitized + capped to 19 chars on encode.
  def subtitle(arg)
    @ble.write(FrameCodec.encode_text(arg))
  end

  # arg: hex-encoded G.711 mu-law bytes (8kHz mono) from SpeechSynth.swift.
  # Writes <A:N>, waits, streams paced chunks, then sits out the device's
  # drain window (N*1000/8000 + 3000 ms from <A:N>) so no later frame gets
  # eaten as audio. Blocks the VM thread for the duration by design; the UI
  # keeps Speak single-flight.
  def speak_audio(hex)
    unless @ble.connected?
      print "not connected; speak dropped\n"
      return
    end
    n = hex.length / 2
    return if n == 0
    chunks = FrameCodec.chunk_audio_hex(hex)
    @ble.write(FrameCodec.encode_audio_header(n))
    msleep(READY_WAIT_MS)
    chunks.each do |c|
      @ble.write_chunk(c)
      msleep(CHUNK_PACE_MS)
    end
    drain_ms = n * 1000 / 8000 + 3000
    remaining = drain_ms - READY_WAIT_MS - chunks.length * CHUNK_PACE_MS
    msleep(remaining + DRAIN_MARGIN_MS) if remaining > 0
    print "audio: #{n} bytes sent\n"
  end
```

- [ ] **Step 4: テストが通ることを確認**

Run: `cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin/examples/ios/stackchan && ruby test_frames.rb`
Expected: 既存分含め全PASS、末尾`all passed`

- [ ] **Step 5: Commit**

```bash
git add examples/ios/stackchan/app.rb examples/ios/stackchan/test_frames.rb
git commit -m "feat(stackchan): subtitle + mu-law audio streaming in app.rb"
```

---

### Task 2: SpeechSynth.swift — TTS→8kHz mono mu-law→hex

**Files:**
- Create: `examples/ios/stackchan/Sources/SpeechSynth.swift`

**Interfaces:**
- Consumes: なし（AVFoundationのみ）
- Produces: `SpeechSynth.shared.synthesize(text: String, completion: @escaping (String?) -> Void)` — 成功時はhex文字列（小文字、G.711 mu-law 8kHz mono）、失敗時nil。completionはmain queueで呼ぶ。Task 3のContentViewが使う

- [ ] **Step 1: 実装を書く**

`examples/ios/stackchan/Sources/SpeechSynth.swift`を新規作成:

```swift
import AVFoundation

// Offline TTS -> G.711 mu-law (8 kHz mono) -> lowercase hex, matching the
// Stack-chan audio wire contract (see docs/superpowers/specs/
// 2026-09-05-stackchan-ios-speak-design.md). AVSpeechSynthesizer.write renders
// buffers without playing anything on the phone; the robot's speaker is the
// only audio output.
final class SpeechSynth: NSObject {
    static let shared = SpeechSynth()

    // Digital gain applied before mu-law encode. 0.175 is the event-proven
    // value from stackchan-picoruby (tools/phrase_announcer.rb).
    private let gain: Float = 0.175
    private let targetRate: Double = 8000.0

    // Keep the synthesizer alive for the whole render; a deallocated
    // synthesizer stops delivering buffers.
    private let synthesizer = AVSpeechSynthesizer()

    func synthesize(text: String, completion: @escaping (String?) -> Void) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")

        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: targetRate,
                                            channels: 1,
                                            interleaved: false) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        var converter: AVAudioConverter?
        var samples: [Float] = []
        var failed = false

        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                // Zero-length buffer marks the end of the utterance.
                let hex = failed ? nil : Self.encodeMuLawHex(samples, gain: self.gain)
                DispatchQueue.main.async { completion(hex) }
                return
            }
            if converter == nil {
                converter = AVAudioConverter(from: pcm.format, to: outFormat)
            }
            guard let conv = converter else { failed = true; return }

            let capacity = AVAudioFrameCount(
                Double(pcm.frameLength) * self.targetRate / pcm.format.sampleRate) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat,
                                             frameCapacity: capacity) else {
                failed = true; return
            }
            var fed = false
            var convError: NSError?
            conv.convert(to: out, error: &convError) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return pcm
            }
            if convError != nil { failed = true; return }
            if let ch = out.floatChannelData {
                samples.append(contentsOf:
                    UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
            }
        }
    }

    private static func encodeMuLawHex(_ samples: [Float], gain: Float) -> String? {
        guard !samples.isEmpty else { return nil }
        var hex = ""
        hex.reserveCapacity(samples.count * 2)
        let digits = Array("0123456789abcdef".utf8)
        for s in samples {
            let scaled = max(-1.0, min(1.0, s * gain))
            let i16 = Int16(scaled * 32767.0)
            let b = muLaw(i16)
            hex.append(Character(UnicodeScalar(digits[Int(b >> 4)])))
            hex.append(Character(UnicodeScalar(digits[Int(b & 0x0f)])))
        }
        return hex
    }

    // Standard G.711 mu-law encoder (bias 0x84 form).
    private static func muLaw(_ sample: Int16) -> UInt8 {
        let bias: Int32 = 0x84
        let clip: Int32 = 32635
        var s = Int32(sample)
        let sign: UInt8 = s < 0 ? 0x80 : 0x00
        if s < 0 { s = -s }
        if s > clip { s = clip }
        s += bias
        var exponent: Int32 = 7
        var mask: Int32 = 0x4000
        while exponent > 0 && (s & mask) == 0 {
            exponent -= 1
            mask >>= 1
        }
        let mantissa = UInt8((s >> (exponent + 3)) & 0x0f)
        return ~(sign | (UInt8(exponent) << 4) | mantissa)
    }
}
```

- [ ] **Step 2: ビルドで検証（このタスクの独立検証）**

Run: `cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin && LANG=en_US.UTF-8 rake ios:stackchan:gen ios:stackchan:device:check`
Expected: BUILD SUCCEEDED（`Sources`はディレクトリ指定なのでSpeechSynth.swiftは自動でターゲットに入る。入らなければproject.ymlを確認）
注意: `device:check`は`gen`を含まない。staleに見えたら`rm -rf build/ios-stackchan-device`ではなくまず`gen`のやり直し。コンパイルエラーが出たらAVAudioConverterまわりの型を合わせて修正してよいが、**ワイヤ契約（8kHz/mono/mu-law/hex/gain 0.175）は変えない**

- [ ] **Step 3: Commit**

```bash
git add examples/ios/stackchan/Sources/SpeechSynth.swift
git commit -m "feat(stackchan): offline TTS to G.711 mu-law hex (SpeechSynth)"
```

---

### Task 3: ContentView — Torque撤去・Speechグループ新設

**Files:**
- Modify: `examples/ios/stackchan/Sources/ContentView.swift`

**Interfaces:**
- Consumes: `SpeechSynth.shared.synthesize(text:completion:)`（Task 2）、vm_callメソッド`"subtitle"` / `"speak_audio"`（Task 1）、既存`VMExecutor.shared.call(_:_:completion:)`と`send(_:_:)`
- Produces: なし（UI終端）

- [ ] **Step 1: Torqueグループを削除しSpeechグループを追加**

`ContentView.swift`の変更点:

(a) `@State`に追加（既存の`connectFailed`の下）:

```swift
    @State private var speakText: String = "ぼくスタックチャン、かわいいよ"
    @State private var speaking: Bool = false
```

(b) `group("Torque") { ... }`のブロック（`HStack`ごと）を丸ごと以下に置換:

```swift
                    group("Speech") {
                        VStack(spacing: 8) {
                            TextField("しゃべらせる言葉", text: $speakText)
                                .textFieldStyle(.roundedBorder)
                            Button("Speak") { speak() }
                                .buttonStyle(.glass)
                                .disabled(speaking || speakText.isEmpty)
                        }
                    }
```

(c) `send(_:_:)`の下にメソッド追加:

```swift
    // Speak is long-running (synthesis, then the VM thread streams audio and
    // sits out the device's drain window): single-flight like connect.
    // Serial-queue ordering makes subtitle land before the audio frames.
    private func speak() {
        speaking = true
        output = "Synthesizing…"
        let text = speakText
        send("subtitle", text)
        SpeechSynth.shared.synthesize(text: text) { hex in
            guard let hex else {
                self.output = "speech synthesis failed"
                self.speaking = false
                return
            }
            VMExecutor.shared.call("speak_audio", hex) { result in
                self.output = result.isEmpty ? "(no output)" : result
                self.speaking = false
            }
        }
    }
```

実装時の確認: 既存の`connect()`はcompletion内で`self.output`を直接触っている。`VMExecutor.shared.call`のcompletionがmainに載る流儀を確認し、載らないなら`DispatchQueue.main.async`で包む（既存connectと同じ扱いに揃える）。

- [ ] **Step 2: ビルドで検証**

Run: `cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin && LANG=en_US.UTF-8 rake ios:stackchan:device:check`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: hostテストのリグレッション確認**

Run: `cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin/examples/ios/stackchan && ruby test_frames.rb`
Expected: `all passed`（torqueメソッドはapp.rbに温存しているのでtorqueテストも通る）

- [ ] **Step 4: Commit**

```bash
git add examples/ios/stackchan/Sources/ContentView.swift
git commit -m "feat(stackchan): Speech UI (text field + speak), drop Torque group"
```

---

### Task 4: 通し検証と実機確認の引き渡し

**Files:**
- なし（検証のみ）

**Interfaces:**
- Consumes: Task 1〜3の成果すべて
- Produces: 検証結果の報告（実機発話はuser実施のため、ここでは「動いた」と書かない）

- [ ] **Step 1: hostテスト・署名不要ビルドの最終確認**

Run:
```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin/examples/ios/stackchan && ruby test_frames.rb
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin && LANG=en_US.UTF-8 rake smoke
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin && LANG=en_US.UTF-8 rake ios:stackchan:device:check
```
Expected: すべて成功

- [ ] **Step 2: 実機確認をuserへ引き渡す**

報告内容: 実機Stack-chan + iPhoneで (1)デフォルト文言の発話 (2)任意文言の発話 (3)字幕表示 (4)音声の途切れ有無、を確認いただく（Claude環境からStack-chan実機へは到達不能なため）。確認完了までは未検証と明記する。
