# tilt-synth — RubyがDevice Motionから鳴らすFM音源

English: [README.md](README.md)

iPhoneを傾けると鳴ります。`app.rb`が`picoruby-iphone-motion` gemのdarwin port
経由でDevice Motionの姿勢（pitchとroll）を読み、pitchを2オクターブのCメジャー
ペンタトニックへ量子化し、rollをFMの深さへマップして、
`picoruby-iphone-synth` gemのdarwin port経由で`AVAudioEngine`のsine + FM
オシレータを駆動します。

どちらのgemのSwiftバックエンドにも音楽的なロジックはありません。音階も範囲も
tickループも、すべてRuby側にあります。

## しくみ

永続VMが`app.rb`を起動し、`$app = TiltSynthApp.new`が代入されてsynthが始まります。
以後`VMExecutor`が単一のVMスレッド上で50msごと（20Hz）に`tick`を呼びます。

```
[CMDeviceMotion の attitude]
  --> ports/darwin/motion.c   Swift @c: pmotion_available / pmotion_pitch / pmotion_roll
  --> include/motion.h        port ABI
  --> src/mruby/motion.c      Motion クラス

app.rb#tick:
  note  = quantize(pitch)                          # -30..+30 度 -> 最寄りのペンタトニック段
  depth = clamp((roll + 45.0) / 90.0, 0.0, 1.0)    # -45..+45 度 -> FM の深さ
  @synth.note = note
  @synth.fm_depth = depth

[Synth#note= / #fm_depth= / #start / #stop]
  --> ports/darwin/synth.c    Swift @c: psynth_start / psynth_stop /
                              psynth_set_note / psynth_set_fm_depth
  --> PicoSynthDarwin（Swift）: AVAudioEngine + AVAudioSourceNode（sine + FM）
  --> スピーカー
```

- ボタンはありません。tickタイマー、したがってsynthは、VM起動の瞬間から動き
  続けます。[virtual-peripheral](../virtual-peripheral/README_jp.md)のpoll tickと
  同じ常時稼働の形です。
- SwiftUIのビューは音楽ロジックを持ちません。`app.rb`がprintしたログ行を表示し、
  最新行からpitchとrollを取り出して2つのゲージを動かすだけです。

## 2つのgem

どちらも`vendor/picoruby`ではなくこのexampleディレクトリに置いたローカルmrbgem
で、[picoruby-iphone-torch](../iphone-torch/README_jp.md)と同じ
`include/` + `src/` + `ports/darwin/` + Swiftパッケージの構成です。どちらもgemの
依存を宣言せず、`pmotion_*`と`psynth_*`のSwiftシンボルは`libmruby.a`内では未定義
のまま、アプリのリンク時に解決されます。

- `picoruby-iphone-motion/` — `CMDeviceMotion`の姿勢を`Motion#pitch` /
  `#roll` / `#available?`として公開。
- `picoruby-iphone-synth/` — `AVAudioEngine`のsine + FMオシレータを
  `Synth#note=` / `#fm_depth=` / `#start` / `#stop`として公開。

## Xcode抜きでマッピングを試す

量子化とクランプの計算はただのRubyなので、デバイスもビルドもXcodeも無しに
ホストCRubyで走ります。

```sh
ruby examples/ios/tilt-synth/test_mapping.rb
```

このスクリプトは通常gemが供給する`Motion`と`Synth`をスタブに差し替えてマッピングを
アサートします。[stackchanの`test_frames.rb`](../stackchan/README_jp.md#フレームのコーデック)
と同じ形です。

## ビルドと実行

前提はフルの`Xcode.app`、iOS SDK、`xcodegen`です。`rake check`で確認できます。

### Simulator

```sh
rake ios:tiltsynth:all     # lib -> gen -> build -> run
```

SimulatorにDevice Motionはありません。アプリは起動しVMも動きますが、
`Motion#available?`が偽になるので`initialize`が一度きりの状態行
`ready: no device motion (Simulator?) -- tick will no-op`をキューします。この行が
起動時ではなく最初のtickで表に出るのは、`flush_log`が`tick`の中で走り、
`VMExecutor`が捕捉するのは`vm_call`のstdoutだけで`vm_open`のものではないから
です。以後アプリは黙ります。このターゲットで確認できるのはビルドがリンクしVMが
動くことまでで、ライトの無い`iphone-torch`におけるSimulatorと同じ役割です。

### 実機

最初の実機ビルドの前に、`project.yml`の`DEVELOPMENT_TEAM: YOUR_TEAM_ID`を自分の
Team IDに置き換えてください。詳細は
[実機で動かす](../../../README_jp.md#実機で動かす)を参照。

```sh
rake ios:tiltsynth:device:all   # 接続済み・署名済みのiPhoneが要る
```

端末を前後に傾けるとpitchがペンタトニックの段を移り、左右に傾けるとFMの深さ、
つまり音色が変わります。これを耳で確かめるのは手作業です。実機での音声の自動
テストはここにはありません。

## 個別タスク

| タスク | 内容 |
|---|---|
| `rake ios:tiltsynth:lib` | 両gem込みでSimulator SDK向けに`libmruby.a`をクロスビルドし`Vendor/`へ配置 |
| `rake ios:tiltsynth:gen` | `project.yml`から`TiltSynth.xcodeproj`を生成 |
| `rake ios:tiltsynth:build` | Simulator向けにビルド |
| `rake ios:tiltsynth:run` | Simulatorを起動しインストールしてlaunch |
| `rake ios:tiltsynth:observe` | 固定Simulatorで繰り返し起動し各runを分類 |
| `rake ios:tiltsynth:device:lib` | device SDK（iphoneos arm64）向けに`libmruby.a`をクロスビルド |
| `rake ios:tiltsynth:device:check` | 署名なしでgeneric device向けにリンク（実機不要） |
| `rake ios:tiltsynth:device:build` | 接続済みデバイス向けに署名してビルド |
| `rake ios:tiltsynth:device:run` | 接続済みデバイスにインストールしてlaunch |
| `rake ios:tiltsynth:device:all` | 実機パイプライン一式 |

## スコープ

これは音楽的マッピングをRubyに置くという主張のPoCであり、意図的にそこで止めて
います。

- GPS高度や気圧センサの入力は無し。
- 連続的なポルタメントは無し（音階は離散的に量子化される）。
- 音階切り替えUI・マイク入力・録音は無し。
- 2つのgemのrp2040 / esp32 portは無し。
