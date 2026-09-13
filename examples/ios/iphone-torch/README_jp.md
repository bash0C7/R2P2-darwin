# iphone-torch — Rubyが駆動する懐中電灯

English: [README.md](README.md)

組み込み開発のhello worldである「Lチカ」の、iOS版です。プログラム全体が`app.rb`の
10行で、マイコン版とまったく同じ読み味です。

```ruby
require "torch"

torch = Torch.new

loop do
  torch.on
  sleep 0.5
  torch.off
  sleep 0.5
end
```

`Torch`は`picoruby-iphone-torch` gemのクラスで、そのdarwin portが`on` / `off`を
`AVCaptureDevice`の操作へ変換します。SwiftUI層はライトのロジックを1つも持たず、
`app.rb`を画面に表示し、RunをタップしたらPicoRuby VMへ渡し、Stopをタップしたら停止フラグを
立てるだけです。

これは[virtual-peripheral](../virtual-peripheral/README_jp.md)の設計、つまり
「Rubyがpicorubyのport経由でAppleのフレームワークを駆動する」を、ハードウェアの
最小プリミティブ（ライト1つのon / off）まで縮めたものです。明るさの制御は対象外
です。

## しくみ

SwiftからVMへの呼び出しはRunのタップ1回だけです。`VMExecutor.start`が`app.rb`を
アプリ内のprismコンパイラでコンパイルして実行します（`vm_open`）。スクリプトの
`loop`は返ってこないので、VMスレッドはStopまでずっと`vm_open`の中に居て
ライトを点滅させ続けます。`vm_call`もpollタイマーもログもなく、出力はライトそのものです。

Stopは別スレッドからVMに触りません。gemの停止フラグ（`src/torch.c`の
`TORCH_request_stop`）を立てるだけで、スクリプトの次の`sleep`がそれを見てライトを消し
`StopIteration`を投げます。`Kernel#loop`がそれをrescueして`loop do ... end`が返り、
`app.rb`が終わって`vm_open`が戻り、VMは自分のスレッド上で閉じられます。Runは新しいVMを
開きます。

```
[SwiftUI の Run ボタン]                    [Stop ボタン] --> TORCH_request_stop()
  --vm_open(app.rb)-->  loop do torch.on / torch.off end（Ruby、VM queue 上）
    --> src/mruby/torch.c           mruby の C メソッド
    --> TORCH_set(true/false)       include/torch.h、port ABI
    --> ports/darwin/torch.c        darwin port
    --> ptorch_set(1/0)             Swift の @c export
    --> AVCaptureDevice.torchMode = .on / .off
```

`app.rb`はバイトコードとしてバイナリに焼き込まれていません。プレーンテキストの
リソースとして同梱されるので、CもSwiftも触らずに点滅を変えられます。

```sh
# examples/ios/iphone-torch/app.rb を編集。例えば sleep 0.1 にする
rake ios:torch:device:build   # .app 内の app.rb リソースを入れ替えるだけ。
                              # libmruby.a と PicoTorchDarwin は無変更
rake ios:torch:device:run     # 入れ直して起動
```

### `sleep`と`require "torch"`はgemが持つ

torchビルドは縮小gemセットで、`mruby-task`にあるのは`sleep_ms`だけ（`Kernel#sleep`
は無い）、`require`もgemが登録した名前しか解決しません。どちらも
`picoruby-iphone-torch/mrblib/torch.rb`（`sleep_ms`に委譲する秒指定の`sleep`）と
`mrbgem.rake`の`spec.require_name = 'torch'`で用意しています。ビルド内で`sleep`を
定義する他のgemは無いので衝突しません。

## gem: `picoruby-iphone-torch/`

`vendor/picoruby`ではなくこのexampleディレクトリに置いたローカルmrbgemです。
picorubyのportsモデルに従い、インターフェースは`include/`に、アーキテクチャ依存の
実装は`ports/<arch>/`に置きます。portは`darwin`だけです。

| パス | 役割 |
|---|---|
| `mrbgem.rake` | gem spec。依存は宣言しない |
| `include/torch.h` | port ABI: `TORCH_set(bool)`、`TORCH_available()` |
| `src/torch.c` | 停止フラグ（`TORCH_request_stop` / `_clear_stop` / `_stop_requested`）とVMディスパッチ（`#include "mruby/torch.c"`） |
| `src/mruby/torch.c` | `Torch`クラス（`on` / `off` / `available?`）を定義するmruby C拡張 |
| `mrblib/torch.rb` | `sleep_ms`の上に`Kernel#sleep(sec)`を定義し`Torch.stop_requested?`を見る。boot時にロード済みなので`require "torch"`は即returnする |
| `ports/darwin/torch.c` | `TORCH_*`からSwiftの`ptorch_*` externへ |
| `ports/darwin/ext/` | `PicoTorchDarwin` Swiftパッケージ（`AVCaptureDevice`） |

`Torch#on` / `#off` / `#available?`はCで定義され、port ABIを呼びます。darwin port
は`PicoTorchDarwin`へ委譲し、その`@c` export（`ptorch_set`、`ptorch_available`）が
`AVCaptureDevice`を包みます。このSwiftパッケージはアプリターゲットにリンクされ、
`libmruby.a`が意図的に未定義のまま残した`ptorch_*`シンボルを解決します。BLE系
exampleの`PicoBLEDarwin`とまったく同じ仕掛けです。

`AVCaptureDevice.lockForConfiguration`経由でライトを操作してもキャプチャ
セッションは始まらないので、このアプリにカメラ権限も`Info.plist`のプライバシー
用途キーも要りません。

## ビルドと実行

前提はフルの`Xcode.app`、iOS SDK、`xcodegen`です。`rake check`で確認できます。

### Simulator

```sh
rake ios:torch:all     # lib -> gen -> build -> run
```

Simulatorにライトはありません。アプリは起動しループも回りますが、`Torch#on`は
何もしません。このターゲットで確認できるのはビルドがリンクしVMが動くことまでです。

### 実機

最初の実機ビルドの前に、`project.yml`の`DEVELOPMENT_TEAM: YOUR_TEAM_ID`を自分の
Team IDに置き換えてください。詳細は
[実機で動かす](../../../README_jp.md#実機で動かす)を参照。

```sh
rake ios:torch:device:all   # 接続済み・署名済みのiPhoneが要る
```

実機ではRunをタップすると、Stopまでライトが1Hzで点滅し続けます。

## 個別タスク

| タスク | 内容 |
|---|---|
| `rake ios:torch:lib` | torch gem込みでSimulator SDK向けに`libmruby.a`をクロスビルドし`Vendor/`へ配置 |
| `rake ios:torch:gen` | `project.yml`から`Torch.xcodeproj`を生成 |
| `rake ios:torch:build` | Simulator向けにビルド |
| `rake ios:torch:run` | Simulatorを起動しインストールしてlaunch |
| `rake ios:torch:observe` | 固定Simulatorで繰り返し起動し各runを分類（golden: `vm_open`直前に出る`[Torch] VM starting`） |
| `rake ios:torch:device:lib` | device SDK（iphoneos arm64）向けに`libmruby.a`をクロスビルド |
| `rake ios:torch:device:check` | 署名なしでgeneric device向けにリンク（実機不要） |
| `rake ios:torch:device:build` | 接続済みデバイス向けに署名してビルド |
| `rake ios:torch:device:run` | 接続済みデバイスにインストールしてlaunch |
| `rake ios:torch:device:all` | 実機パイプライン一式 |
