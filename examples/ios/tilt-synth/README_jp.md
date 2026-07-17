# Tilt Synth — Ruby が駆動する Device Motion FM シンセサイザー

English: [README.md](README.md)

iPhone を傾けると Ruby が音を変える技術 PoC です。`app.rb` が
`picoruby-iphone-motion` gem の Darwin port を通じて Device Motion の
attitude (pitch/roll) を読み取り、pitch を 2 オクターブの C major pentatonic
scale に量子化、roll を FM depth に写像し、`picoruby-iphone-synth` gem の
Darwin port を通じて `AVAudioEngine` の sine+FM オシレーターを駆動します。
両 gem の Swift backend に音楽的な mapping ロジックは一切なく、スケール・
レンジ・tick ループはすべて `app.rb` にあります。構成は picoruby-ot の
`otmeiwa.rb` (センサー読み取り) + `web/` (センサーから音楽への mapping) の
ペアを、シリアルリンクもブラウザも外部センサーボードも無しで 1 つのネイティブ
iOS アプリに畳み込んだものです。

## 仕組み

常駐する PicoRuby VM が `app.rb` を起動し (`$app = TiltSynthApp.new` が
Synth を start します)、以後 `VMExecutor` が単一の VM スレッド上で 20 Hz の
`tick` を呼び続けます。

```
[CMDeviceMotion attitude]
  --> ports/darwin/motion.c   (Swift @c: pmotion_available/pmotion_pitch/pmotion_roll)
  --> include/motion.h        (port ABI)
  --> src/mruby/motion.c      (Motion class)

app.rb tick:
  note  = quantize(pitch)                          # -30..+30 deg -> PENTATONIC_SCALE の最寄りステップ
  depth = clamp((roll + 45.0) / 90.0, 0.0, 1.0)    # -45..+45 deg -> FM depth
  @synth.note = note
  @synth.fm_depth = depth

[Synth#note= / #fm_depth= / #start / #stop]
  --> ports/darwin/synth.c    (Swift @c: psynth_start/psynth_stop/psynth_set_note/psynth_set_fm_depth)
  --> Swift PicoSynthDarwin: AVAudioEngine + AVAudioSourceNode (sine + FM)
  --> スピーカー
```

- ボタンはありません。tick タイマー (つまり synth) は VM 起動の瞬間から
  動き続けます。`virtual-peripheral` の poll tick と同じ常時稼働モデルです。
- SwiftUI の view は音楽ロジックを持ちません。`app.rb` が print するログ行を
  表示し、最新の行から pitch/roll を読み取って 2 本のゲージに反映するだけです。

## gem 構成

どちらもローカルの mrbgem で (`vendor/picoruby` には入っていません)、
`picoruby-iphone-torch` と同じ `include/` + `src/` + `ports/darwin/` +
Swift package の構造です。gem としての依存宣言は持たず、`pmotion_*` /
`psynth_*` の Swift シンボルはアプリのリンク時に解決されます。

- `picoruby-iphone-motion/` — CMDeviceMotion の attitude.pitch/roll を
  `Motion#pitch` / `#roll` / `#available?` として公開
- `picoruby-iphone-synth/` — AVAudioEngine の sine+FM オシレーターを
  `Synth#note=` / `#fm_depth=` / `#start` / `#stop` として公開

## Xcode なしで mapping ロジックをテストする

quantize/clamp の計算はホストの CRuby でそのまま動きます。実機もビルドも
Xcode も不要です。

```sh
ruby examples/ios/tilt-synth/test_mapping.rb
```

- 通常は gem が提供する `Motion`/`Synth` をスタブに差し替え、quantize/clamp
  の計算を検証します。`examples/ios/stackchan/test_frames.rb` と同じ
  パターンです。

## ビルドと実行

前提: フルの `Xcode.app`、iOS SDK、`xcodegen` (`rake check` で確認できます)。

### Simulator

```sh
rake ios:tiltsynth:all     # libmruby.a の cross-build -> xcodegen -> build -> 起動
```

- Simulator に Device Motion はありません。アプリは起動し VM も動きますが、
  `Motion#available?` が `false` のため、`initialize` が一度きりの status 行
  "ready: no device motion (Simulator?) -- tick will no-op" をキューに積みます。
  この行がログに現れるのは最初の tick です (`flush_log` は `tick` の中で走り、
  `VMExecutor` が capture するのは `vm_call` の stdout だけで、`vm_open` の分は
  拾わないため)。音は鳴りません。
- この target はビルドがリンクでき VM が動くことの確認用です。torch を
  持たない `iphone-torch` の Simulator target と同じ位置づけです。

### 実機 (実際に傾けて音を出す)

初回は `project.yml` の `DEVELOPMENT_TEAM: YOUR_TEAM_ID` を自分の Team ID に
置き換えてください。詳細は [実機ビルド](../../../README_jp.md#実機ビルド) を
参照してください。

```sh
rake ios:tiltsynth:device:all   # 接続済みで署名可能な iOS 実機が必要
```

- 実機の iPhone では、前後に傾けると pitch がペンタトニックの離散ステップで
  変わり、左右に傾けると FM depth (音色) が変わります。
- これを耳と目で確かめるのは手動の手順です。この repo に実機上の自動テストは
  ありません。

## 個別の rake タスク

pipeline の各段階は単独の task としても実行できます。

- `rake ios:tiltsynth:lib` — 両 gem を含む `libmruby.a` を Simulator 向けに
  cross-build し `Vendor/` に配置
- `rake ios:tiltsynth:gen` — `project.yml` から `TiltSynth.xcodeproj` を生成
- `rake ios:tiltsynth:build` — Simulator 向けにアプリをビルド
- `rake ios:tiltsynth:run` — Simulator を起動し、インストールして launch
- `rake ios:tiltsynth:device:lib` — 実機 SDK (iphoneos arm64) 向けに
  `libmruby.a` を cross-build
- `rake ios:tiltsynth:device:build` — 接続済み実機向けに署名付きでビルド
- `rake ios:tiltsynth:device:run` — 接続済み実機にインストールして launch

## 既知の制約

この PoC は以下を意図的にスコープ外としています。

- GPS 高度 / 気圧計は使いません。
- 連続的なポルタメントはありません (離散的なスケール量子化のみ)。
- スケール切替 UI・マイク入力・録音はありません。
- rp2040/esp32 port はありません。
