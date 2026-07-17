# iPhone Torch — Ruby で動かすフラッシュライト

English: [README.md](README.md)

iOS 版の「L チカ」です。ON / OFF の 2 つのボタンで iPhone のトーチ (フラッシュライト) を
点灯・消灯しますが、その挙動はすべて Ruby にあります。`app.rb` が `Torch` クラスを呼び、
`picoruby-iphone-torch` gem の Darwin port がその呼び出しを `AVCaptureDevice` の
トーチ操作に変換します。SwiftUI 層はトーチのロジックを一切持たず、PicoRuby VM の起動と
ボタンタップの転送だけを担います。

設計は `../virtual-peripheral` (Ruby が picoruby port を通じて Apple framework を駆動する)
と同じ考え方を、最小のハードウェア primitive (単一のオン/オフのライト) に縮めたものです。
明るさ (level) の制御はスコープ外で、扱うのは点灯と消灯のみです。

## 仕組み

ボタンを 1 回押すごとに `vm_call` が 1 回走ります。戻り値は `app.rb` が print した内容
(captured stdout) で、UI がそれをログに追記します。

```
[SwiftUI ON / OFF buttons]
  --vm_call(vm, "on"/"off", "")-->  $app (TorchApp, Ruby)  -->  Torch#on / #off
    --> src/mruby/torch.c      (mruby C method)
    --> TORCH_set(true/false)  include/torch.h (port ABI)
    --> ports/darwin/torch.c   Darwin port
    --> ptorch_set(1/0)        Swift @c export
    --> AVCaptureDevice.torchMode = .on/.off
```

virtual-peripheral と違い poll timer はありません。トーチは fire-and-forget の
オン/オフなので、1 回の押下につき `vm_call` が 1 回で完結します。

`app.rb` は bytecode としてバイナリに焼き込まれてはいません。プレーンテキストの
resource として同梱され、VM の起動時 (`VMExecutor.start` -> `vm_open(bootSource)`) に
アプリの中で PicoRuby の prism compiler が実行時コンパイルします。トーチをいつ点けるか、
どう点滅させるか、何をログに出すか — アプリの挙動はすべてこの Ruby ファイルにあります。
C gem は `Torch` primitive (`on` / `off` / `available?`) を公開するだけ、Swift package は
`AVCaptureDevice` を叩くだけで、どちらにも「点滅」や「カウント」のロジックはありません。

これを具体的に示すため、ON では Ruby で定義した点滅が走ります。`app.rb` 内の `while`
ループが `sleep_ms(BLINK_MS)` を挟みながら `@torch.on` / `@torch.off` を `BLINK_COUNT` 回
呼び、その後トーチを点灯したままにします。押した回数のカウントも Ruby 側です。
ループが Ruby、光がハードウェアという、文字どおりの「L チカ」です。

点滅パターンの変更に C / Swift の rebuild は不要です:

```sh
# examples/ios/iphone-torch/app.rb を編集 (例: BLINK_COUNT = 7)
rake ios:torch:device:build   # app.rb resource を .app に再コピーするだけ
                              # (libmruby.a と PicoTorchDarwin は手つかず)
rake ios:torch:device:run     # 再インストールして起動
```

これでトーチは 7 回点滅します。変更したのは Ruby だけで、コンパイル済みの C gem と
Swift backend はバイト単位で同一のままです。`sleep_ms` は `mruby-task` の Kernel 関数で、
iOS では bridge HAL (`bridge/task_hal_ios.c`) を通じて実時間で block するため、
点滅の間隔は本物の時間です。

## gem: `picoruby-iphone-torch/`

ローカルの mrbgem です (`vendor/picoruby` には含まれません)。picoruby の ports モデルに
従い、インターフェースは `include/`、アーキテクチャ固有の実装は `ports/<arch>/` に
置かれます。port は `darwin` (iPhone/iOS) のみです。

- `mrbgem.rake` — gem spec (依存なし)
- `include/torch.h` — port ABI: `TORCH_set(bool)` / `TORCH_available()`
- `src/torch.c` — VM dispatch (`#include "mruby/torch.c"`)
- `src/mruby/torch.c` — mruby C 拡張。`Torch` クラス (`on` / `off` / `available?`) を定義
- `ports/darwin/torch.c` — `TORCH_*` -> Swift `ptorch_*` (extern をここで宣言)
- `ports/darwin/ext/` — Swift package `PicoTorchDarwin` (`AVCaptureDevice` backend)

`Torch#on` / `#off` / `#available?` は C で定義され、port ABI を呼びます。Darwin port は
`PicoTorchDarwin` Swift package に委譲し、その `@c` export (`ptorch_set` /
`ptorch_available`) が `AVCaptureDevice` を包みます。Swift package はアプリ target に
リンクされ、`libmruby.a` 内で未解決のまま残る `ptorch_*` シンボルをそこで解決します。
BLE example の `PicoBLEDarwin` と同じパターンです。

トーチ制御は `AVCaptureDevice.lockForConfiguration` 経由で capture session を開始しない
ため、カメラの permission も privacy key も不要です。

## ビルドと実行

前提はフル版の `Xcode.app`、iOS SDK、`xcodegen` です (`rake check` で確認できます)。

### Simulator

```sh
rake ios:torch:all     # libmruby.a の cross-build -> xcodegen -> build -> 起動
```

Simulator にトーチはありません。アプリは起動し VM も動きますが、ON は点滅の代わりに
`ON #<n>: torch unavailable (no actuation)` をログに出します。この target はビルドが
リンクでき VM が動くことの確認用です。

### 実機 (実際のトーチ)

初回の実機ビルドの前に、`project.yml` の `DEVELOPMENT_TEAM: YOUR_TEAM_ID` を
自分の Team ID に置き換えてください。詳細は
[実機ビルド](../../../README_jp.md#実機ビルド) を参照してください。

```sh
rake ios:torch:device:all   # 接続済みで署名できる iOS device が必要
```

実機の iPhone では、ON でトーチが `BLINK_COUNT` 回点滅したあと点灯したままになり
(ログは `ON #<n>: blinked <BLINK_COUNT>x in Ruby, now lit`)、OFF で消灯します。

## 個別の rake タスク

pipeline の各段階は単独の task としても実行できます。

- `rake ios:torch:lib` — torch gem 込みの `libmruby.a` を Simulator 向けに cross-build し `Vendor/` に配置
- `rake ios:torch:gen` — `project.yml` から `Torch.xcodeproj` を生成
- `rake ios:torch:build` — Simulator 向けにアプリを build
- `rake ios:torch:run` — Simulator を起動し、インストールして launch
- `rake ios:torch:device:lib` — device SDK (iphoneos arm64) 向けに `libmruby.a` を cross-build
- `rake ios:torch:device:build` — 接続済み device 向けに署名付きで build
- `rake ios:torch:device:run` — 接続済み device にインストールして launch
