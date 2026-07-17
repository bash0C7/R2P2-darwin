# R2P2-darwin

[![CI](https://github.com/bash0C7/R2P2-darwin/actions/workflows/ci.yml/badge.svg)](https://github.com/bash0C7/R2P2-darwin/actions/workflows/ci.yml)

English: [README.md](README.md)

PicoRuby を Apple プラットフォームでビルド・実行するための自己完結型ハーネスです。
対象は macOS ホスト、iOS (Simulator および署名済み実機)、watchOS の 3 つです。
picoruby を静的ライブラリにクロスビルドし、薄い C ブリッジを介して SwiftUI アプリに
リンクします。付属の example はアプリの振る舞いを Ruby 側に置く構成です。picoruby
は prism コンパイラを VM に焼き込んでいるため、アプリはデバイス上で実行時に Ruby
ソースをコンパイル・実行できます。

## はじめる

Apple プラットフォームで PicoRuby が動くまでの最短経路です — iOS Simulator で
repl example を動かします。署名は不要です:

1. フル Xcode.app をインストールし (App Store から。Command Line Tools だけでは
   足りません)、ツールチェーンを向けます:

   ```sh
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -license accept
   ```

2. `brew install xcodegen`

3. clone して前提を確認します:

   ```sh
   git clone https://github.com/bash0C7/R2P2-darwin.git
   cd R2P2-darwin
   rake check
   ```

4. `rake ios`

`rake ios` は picoruby を `vendor/picoruby` に取得し (初回のみ。submodule 込みで
約 1.2 GB、ビルド生成物込みでリポジトリ全体は約 3 GB になります)、`libmruby.a`
をクロスビルドし、Xcode プロジェクトを生成してアプリをビルドし、Simulator で
起動します。アプリに `puts "hello #{1 + 2}"` と入力して Run をタップすると
`hello 3` と表示されます — アプリ内の PicoRuby がコンパイル・実行した結果です。

Ruby は手元の環境 (rbenv / asdf / system) の 2.7 以上ならなんでも構いません。
`.ruby-version` はバージョンマネージャ向けに 4.0.5 を固定しています。

## これは何か

`R2P2-darwin` は picoruby を Apple のビルドシステム (iOS / watchOS では Xcode /
xcodebuild / Simulator / 署名、macOS ホストでは clang + Swift) に接続します。
[R2P2-ESP32](https://github.com/picoruby/R2P2-ESP32) の Apple 版にあたる
位置づけで、iOS / watchOS が ESP-IDF と同様にそれ自体が大きな外部ビルドシステム
であるため、独立したハーネスになっています。

picoruby は PicoRuby の共通コアで、各 mrbgem が `mrbgems/<gem>/ports/<arch>/`
(rp2040 / posix / esp32 / darwin など) にアーキテクチャ別実装を同一インター
フェースで持ちます。R2P2-darwin の役割は、Apple 向けの port を選択するビルド設定
と、C ブリッジ、example アプリを保持することです。Apple 固有のグルーはこの repo
に置き、picoruby のツリーには手を入れません。

すべてのプラットフォームが単一の `vendor/picoruby` チェックアウトを共有します。
`rake setup` が取得し (各 lib タスクが setup に依存するため、必要になれば自動でも
走ります)、`rake refresh` が既存のチェックアウトに `PICORUBY_REF` を再取得します。
ビルド成果物は `./build` (`MRUBY_BUILD_DIR`) に出るため、取得したソースが変更される
ことはありません。環境変数:

| 変数 | デフォルト | 制御対象 |
|---|---|---|
| `PICORUBY_REPO` | `https://github.com/bash0C7/picoruby.git` | picoruby の取得元 |
| `PICORUBY_REF` | `port-darwin` | 取得する ref — master + darwin ports + net fix ([Vendor fork](#vendor-fork) 参照) |
| `IOS_MIN` | `17.0` | iOS deployment minimum (iOS ビルド設定が読みます) |
| `WATCHOS_MIN` | `11.0` | watchOS deployment minimum (watchOS ビルド設定が読みます) |
| `PICORUBY_BLE_GEMDIR` | vendor の `picoruby-ble` | BLE example 用の picoruby-ble 代替チェックアウト |

## Examples

各 iOS / watchOS example は振る舞いが `app.rb` にある SwiftUI アプリで、それぞれ
詳細な README を持ちます。`rake <ns>:all` が Simulator パイプライン
(lib → gen → build → run)、`rake <ns>:device:all` が接続実機へのビルド・署名・
インストール・起動です — [実機ビルド](#実機ビルド) を参照してください。

| Example | rake namespace | 見どころ |
|---|---|---|
| [ios/repl](examples/ios/repl/README_jp.md) | `ios:repl` (`ios` が alias) | アプリに打ち込んだ Ruby を評価する full-REPL VM |
| [ios/networking](examples/ios/networking/README_jp.md) | `ios:net` | Ruby から HTTP/TLS — mbedTLS 上の picoruby-net、URLSession 不使用 |
| [ios/virtual-peripheral](examples/ios/virtual-peripheral/README_jp.md) | `ios:vperiph` | Ruby で書いた BLE ペリフェラル (picoruby-ble darwin port 経由の CoreBluetooth) |
| [ios/iphone-torch](examples/ios/iphone-torch/README_jp.md) | `ios:torch` | iPhone の「L チカ」: `app.rb` が駆動するフラッシュライト |
| [ios/stackchan](examples/ios/stackchan/README_jp.md) | `ios:stackchan` | [Stack-chan](https://github.com/meganetaaan/stack-chan) を NUS 越しに駆動する BLE セントラル |
| [ios/tilt-synth](examples/ios/tilt-synth/README_jp.md) | `ios:tiltsynth` | Device Motion FM シンセ — 音のマッピングは `app.rb` にあります |
| [watchos/led-toggle](examples/watchos/led-toggle/README_jp.md) | `watchos:led` | Apple Watch 上の Ruby な LED 点滅 (arm64_32) |

例: `rake ios:torch:all` (Simulator) / `rake ios:torch:device:all` (接続中の
iPhone)。`rake ios:vperiph:write` は、ペリフェラルを Mac 側から叩く macOS BLE
セントラルヘルパーをビルドします (`WRITE_HEX` などは環境変数で渡します)。

### macOS ホスト

macOS では picoruby をネイティブに動かします — example アプリではなくホスト
ビルドモードです。出力は `./build/host/bin` に出ます。`rake macos:check` が
ホスト前提を検証します (Command Line Tools で足ります。Homebrew `openssl@3` は
networking gembox を引くホストビルドでのみ必要です)。

```sh
rake macos:build                                # ./build/host/bin/{r2p2,picoruby}
rake macos:run                                  # r2p2 シェル
rake macos:run APP=path/to.rb                   # Ruby ファイルを実行
rake macos:single APP=examples/macos/ls/ls.rb   # スクリプトを埋め込んだ自己完結バイナリ
```

`MRUBY_CONFIG` でビルド設定を選択します (デフォルトは Darwin ホスト base の
`build_config/r2p2-picoruby-darwin.rb`。`r2p2-picoruby-darwin-ble.rb` で
picoruby-ble / CoreBluetooth をオプトインします)。

## 実機ビルド

device 系タスクは、接続中の iPhone / Apple Watch に対して automatic signing で
ビルドします。初回の実機ビルドの前に:

1. Xcode → Settings → Accounts で自分の Team ID を確認します (無料の Apple ID
   で構いません)。
2. example の `project.yml` の `DEVELOPMENT_TEAM: YOUR_TEAM_ID` を自分の
   Team ID に置き換えます。チーム内で bundle id が衝突する場合は
   `bundleIdPrefix` も変更してください。
3. bundle id ごとに初回起動時、実機側で一度だけ信頼が必要です:
   設定 → 一般 → VPN とデバイス管理 → 自分の Apple ID → 信頼。

## 全体の組み合わさり方

```
examples/ios/<name>/Sources (SwiftUI)
        │  Swift ⇄ C ブリッジングヘッダ
        ▼
bridge/picoruby_bridge.c   ──▶  libmruby.a (iOS arm64)
  repl_eval(src)                  prism コンパイラ + mruby VM
  vm_open / vm_call / vm_close    vendor/picoruby から
                                  build_config/r2p2-picoruby-ios-<name>-{sim,device}.rb
                                  でクロスビルド
```

- `bridge/picoruby_bridge.c` — `repl_eval(src)` は新しい VM で Ruby を評価して
  stdout/stderr をキャプチャします。`vm_open`/`vm_call`/`vm_close` は永続 VM を
  保持し、Ruby グローバル `$app` のメソッドを呼びます (`repl` 以外の全 example)。
  VM に触るのは単一のオーナースレッドだけです。
- `bridge/task_hal_ios.c` — iOS 用のポーリング型タスクスケジューラ HAL です
  (SIGALRM 不使用)。
- gem は静的リンクで、実行時 `require` はありません。ビルド設定の mrbgem は
  すべて `libmruby.a` にコンパイルされ VM 起動時に登録されるため、`app.rb` は
  `BLE` などのクラスを直接使えます。example にクラスを増やすには、その example
  のビルド設定に gem を足します。

gembox の形は example ごとに 2 種が併存します。`repl` と `networking` は
full-REPL gembox (`mruby-posix` + `core` + `stdlib` + `shell`、
`conf.ports :darwin, :posix`) — リンクが大きくなる代わりにフルの Ruby 表面積を
得ます。他の example は POSIX なしの reduced gem set で、コア Ruby のみです —
`puts` は無く (ブリッジが `print` の上に shim を入れます)、`defined?` /
`String#ord` / `String#%` もありません。それ以上が要る example (`Array#pack` や
`sprintf` など) は example 専用のビルド設定に gem を足します —
`examples/ios/stackchan` を参照してください。新しく Ruby を焼き込む前には
`rake smoke` のホストビルドで動作を確かめるのがおすすめです。

## Vendor fork

デフォルトの vendor 取得元 (`bash0C7/picoruby` の `port-darwin` branch) は、
upstream master に darwin ports (ble / rng / mbedtls / io-console / machine) と、
iOS networking が依存する picoruby-net POSIX port のアロケータ修正 (iOS ブリッジ
は VM を estalloc プール上で動かすため、受信バッファは VM アロケータ由来である
必要があります) を加えたものです。upstream `picoruby/picoruby` の master には
どちらも無いため、`PICORUBY_REF` を upstream に向けると `networking` /
`virtual-peripheral` / `stackchan` が壊れます。これらを含む fork/branch なら
何でもよく、vendor を特定の ref に固定する規則ではありません。

## 動作確認済み環境

| | 確認バージョン |
|---|---|
| macOS | 26.5 |
| Xcode | 26.5 (17F42) |
| Ruby | 4.0.5 |

実機ビルドは、物理 iPhone (arm64) と Apple Watch (arm64_32) に対して、無料
Apple ID の personal team で動作確認済みです。

## レイアウト

```
R2P2-darwin/
  Rakefile                  check / setup / refresh / smoke / ios:<example>:* / watchos:led:* / clean / clobber
  rakelib/macos.rake        macos:check / macos:build / macos:run / macos:single
  build_config/             MRuby ビルド設定: r2p2-picoruby-ios-<example>-{sim,device}.rb、
                            r2p2-picoruby-watchos-{sim,device}.rb + recompile_arm64_32.rb、
                            r2p2-picoruby-darwin*.rb (macOS ホスト)、r2p2-picoruby-host.rb (rake smoke)
  bridge/                   picoruby_bridge.{c,h}、task_hal_ios.c、smoke_test.c
  examples/
    ios/<name>/             SwiftUI アプリ + app.rb (example ローカル gem を持つものもあります)
    macos/ls/               rake macos:single のデモスクリプト
    watchos/led-toggle/     watchOS の example
  vendor/picoruby/          rake setup が取得 (gitignore 済み)
  build/                    ビルド出力、MRUBY_BUILD_DIR (gitignore 済み)
```

## ライセンス

[MIT](LICENSE)
