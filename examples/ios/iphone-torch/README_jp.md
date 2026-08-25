# iphone-torch — Rubyが駆動する懐中電灯

English: [README.md](README.md)

組み込み開発のhello worldである「Lチカ」の、iOS版です。2つのボタンでiPhoneの
ライトをon / offし、その振る舞いはすべてRubyにあります。`app.rb`が`Torch`
クラスを呼び、`picoruby-iphone-torch` gemのdarwin portがその呼び出しを
`AVCaptureDevice`の操作へ変換します。SwiftUI層はライトのロジックを1つも持たず、
PicoRuby VMを起動してボタンのタップを転送するだけです。

これは[virtual-peripheral](../virtual-peripheral/README_jp.md)の設計、つまり
「Rubyがpicorubyのport経由でAppleのフレームワークを駆動する」を、ハードウェアの
最小プリミティブ（ライト1つのon / off）まで縮めたものです。明るさの制御は対象外
です。

## しくみ

ボタン1押しが`vm_call` 1回に対応します。戻り値は`app.rb`がprintした内容で、UIは
それをログに追記します。

```
[SwiftUI の ON / OFF ボタン]
  --vm_call(vm, "on"/"off", "")-->  $app（TorchApp、Ruby）  -->  Torch#on / #off
    --> src/mruby/torch.c           mruby の C メソッド
    --> TORCH_set(true/false)       include/torch.h、port ABI
    --> ports/darwin/torch.c        darwin port
    --> ptorch_set(1/0)             Swift の @c export
    --> AVCaptureDevice.torchMode = .on / .off
```

virtual-peripheralと違い、ここにpollタイマーはありません。ライトは撃ちっぱなしで
よいので、1押しにつき`vm_call` 1回で話が終わります。

`app.rb`はバイトコードとしてバイナリに焼き込まれていません。プレーンテキストの
リソースとして同梱され、起動時にアプリ内のprismコンパイラがコンパイルします
（`VMExecutor.start` → `vm_open(bootSource)`）。いつライトを点けるか、どう
点滅させるか、何をログに出すか——それらはすべてそのRubyファイルにあります。C gem
が公開するのは`Torch`プリミティブ（`on` / `off` / `available?`）だけ、Swift
パッケージがやるのは`AVCaptureDevice`を叩くことだけで、どちらも点滅や回数の
ロジックを持ちません。

### 点滅はRubyのループ

具体的に言うと、ONはRubyで定義された点滅を走らせます。`app.rb`の`while`ループが
`@torch.on`と`@torch.off`を`BLINK_COUNT`回、間に`sleep_ms(BLINK_MS)`を挟んで呼び、
最後はライトを点けたままにし、押した回数もRubyで数えます。文字通りのLチカで、
ループがRuby、光がハードウェアです。

CもSwiftも触らずに点滅を変えられます。

```sh
# examples/ios/iphone-torch/app.rb を編集。例えば BLINK_COUNT = 7 にする
rake ios:torch:device:build   # .app 内の app.rb リソースを入れ替えるだけ。
                              # libmruby.a と PicoTorchDarwin は無変更
rake ios:torch:device:run     # 入れ直して起動
```

これでライトは7回光ります。変えたのはRubyだけで、コンパイル済みのC gemとSwift
バックエンドは1バイトも同じです。

`sleep_ms`は`mruby-task`由来のKernel関数です。iOSではブリッジのtask HAL
（`../../../bridge/task_hal_ios.c`）を通して実時間でblockするので、点滅の間の
休みはビジーウェイトではなく本物の待ちです。

## gem: `picoruby-iphone-torch/`

`vendor/picoruby`ではなくこのexampleディレクトリに置いたローカルmrbgemです。
picorubyのportsモデルに従い、インターフェースは`include/`に、アーキテクチャ依存の
実装は`ports/<arch>/`に置きます。portは`darwin`だけです。

| パス | 役割 |
|---|---|
| `mrbgem.rake` | gem spec。依存は宣言しない |
| `include/torch.h` | port ABI: `TORCH_set(bool)`、`TORCH_available()` |
| `src/torch.c` | VMへのdispatch（`#include "mruby/torch.c"`） |
| `src/mruby/torch.c` | `Torch`クラス（`on` / `off` / `available?`）を定義するmruby C拡張 |
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

Simulatorにライトはありません。アプリは起動しVMも動きますが、ONは点滅せず
`ON #<n>: torch unavailable (no actuation)`とログに出ます。このターゲットで
確認できるのはビルドがリンクしVMが動くことまでです。

### 実機

最初の実機ビルドの前に、`project.yml`の`DEVELOPMENT_TEAM: YOUR_TEAM_ID`を自分の
Team IDに置き換えてください。詳細は
[実機で動かす](../../../README_jp.md#実機で動かす)を参照。

```sh
rake ios:torch:device:all   # 接続済み・署名済みのiPhoneが要る
```

実機ではONがライトを`BLINK_COUNT`回光らせてから点けたままにし
（ログは`ON #<n>: blinked <BLINK_COUNT>x in Ruby, now lit`）、OFFで消えます。

## 個別タスク

| タスク | 内容 |
|---|---|
| `rake ios:torch:lib` | torch gem込みでSimulator SDK向けに`libmruby.a`をクロスビルドし`Vendor/`へ配置 |
| `rake ios:torch:gen` | `project.yml`から`Torch.xcodeproj`を生成 |
| `rake ios:torch:build` | Simulator向けにビルド |
| `rake ios:torch:run` | Simulatorを起動しインストールしてlaunch |
| `rake ios:torch:observe` | 固定Simulatorで繰り返し起動し各runを分類 |
| `rake ios:torch:device:lib` | device SDK（iphoneos arm64）向けに`libmruby.a`をクロスビルド |
| `rake ios:torch:device:check` | 署名なしでgeneric device向けにリンク（実機不要） |
| `rake ios:torch:device:build` | 接続済みデバイス向けに署名してビルド |
| `rake ios:torch:device:run` | 接続済みデバイスにインストールしてlaunch |
| `rake ios:torch:device:all` | 実機パイプライン一式 |
