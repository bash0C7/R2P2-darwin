# PicoRuby on iOS — Ruby Runner（R2P2-iOS サブプロジェクト 1）設計

- 日付: 2026-06-20
- repo: R2P2-iOS（新設・自己完結）
- ステータス: 設計確定（実装前）

## この repo の位置づけ

R2P2-iOS は **R2P2-ESP32 と並列の自己完結 harness repo**。picoruby を iOS という
別建て build system（Xcode / xcodebuild / Simulator / 署名）へ接続する。

R2P2-macOS との対比が重要：

- **R2P2-macOS** は薄い・transitional。macOS host には ESP-IDF 級の外部 build system
  が無く、picoruby が Darwin host build config を取り込めば役目を終える。
- **R2P2-ESP32** は恒久。ESP-IDF という substantial な外部 build system を接続する。
- **R2P2-iOS** は後者の類型。iOS は Xcode / xcodebuild / Simulator / 署名という ESP-IDF
  級の別建て build system を持つため、自己完結の harness として独立する。

結果として **R2P2-iOS は R2P2-macOS に一切依存しない**。iOS 向け build config・C ブリッジ・
SwiftUI アプリ・picoruby の fetch/build wrapper を全部自分で抱える。cross-repo の
build-artifact 依存（別 repo の build/ を覗く類）は作らない。

## 背景

picoruby は prism コンパイラを VM 内に同梱しており、産出物 `libmruby.a` 単体で
「Ruby ソースを実行時にコンパイル＆実行する能力」を持つ。iOS Simulator も Darwin /
Xcode ツールチェーン上のクロスビルドで、picoruby tree には既にクロスビルド先例
（`r2p2-picoruby-pico2.rb` は ARM 向け `MRuby::CrossBuild`）がある。同じ要領で iOS SDK
を `xcrun` 経由で叩けば iOS 向け `libmruby.a` を産出でき、それを SwiftUI アプリに
リンクすれば iOS 上で Ruby を走らせられる。本設計はその最小の縦切り 1 本を Simulator
で通すもの。

## ゴール / 非ゴール

### ゴール
- iOS Simulator 上で動く SwiftUI アプリ。画面で Ruby ソースを入力 → Run →
  `puts` 等の出力を画面に表示。
- `rake ios` 一発で fetch（picoruby）→ ios:lib → xcodegen → xcodebuild → simctl
  install/launch までヘッドレス完結。

### 非ゴール（後続スペックで土台の上に載せる）
- 実機配布・Apple Developer 署名（Personal Team 含む）
- CoreBluetooth / BLE 連携
- ネットワーキング、ファイル I/O 系 gem
- VM 状態の呼び出し間持ち越し（MVP は毎回 open/close）

## 前提（prerequisites）

- **フル Xcode.app（必須）**: iOS Simulator・iOS SDK・`xcodebuild` を提供。Command
  Line Tools だけでは不足。Mac App Store または Apple Developer の More Downloads
  から無料 Apple ID で取得（有料加入不要）。インストール後に
  `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`、
  `sudo xcodebuild -license accept`、必要なら `xcodebuild -downloadPlatform iOS`。
- **xcodegen**: `brew install xcodegen`。
- **Ruby**: ambient（rbenv / asdf / system）>= 2.7。
- これらは `rake check` で verify する。

## repo 構成

```
R2P2-iOS/
  Rakefile                              # fetch picoruby + ios build + xcodegen/xcodebuild/simctl
  build_config/
    r2p2-picoruby-ios-sim.rb            # iOS Simulator (arm64) CrossBuild
    r2p2-picoruby-host.rb              # host build（bridge smoke test 用）
  bridge/
    picoruby_bridge.h                   # ブリッジ宣言
    picoruby_bridge.c                   # eval + 出力捕捉
    smoke_test.c                        # host smoke test
  app/
    project.yml                         # xcodegen spec
    Sources/
      App.swift                         # @main SwiftUI entry
      ContentView.swift                 # UI
      PicoRubyRunner-Bridging-Header.h  # ブリッジを Swift へ公開
    Vendor/                             # 生成物（gitignore）: libmruby.a + headers
  vendor/picoruby/                      # fetch 物（gitignore）
  build/                                # ビルド出力（gitignore）
```

## アーキテクチャ（4 層）

```
SwiftUI (ContentView)  ──呼ぶ──▶  Swift→C ブリッジ (bridging header)
        │                              │
        ▼                              ▼
  画面: 入力 / Run / 出力        picoruby_eval(const char *src) -> char*
                                       │ (実行中の stdout/stderr を fd リダイレクトで捕捉)
                                       ▼
                            libmruby.a (iOS arm64-simulator)
                            = prism compiler + mruby VM 同梱
```

## コンポーネントと責務

### 1. `Rakefile`（自前の picoruby fetch/build wrapper）
R2P2-macOS の fetch パターンを踏襲（自己完結なので依存ではなく同型の再実装）：
- `PICORUBY_REPO`（default `https://github.com/picoruby/picoruby.git`）/ `PICORUBY_REF`
  （default `master`）で picoruby tree を `vendor/picoruby` に clone
- `MRUBY_BUILD_DIR=./build` で fetched source を pristine に保つ
- タスク: `check` / `setup` / `refresh` / `ios:lib` / `ios:gen` / `ios:build` /
  `ios:run` / `ios`（連結）/ `host:lib` / `smoke` / `clean` / `clobber`

### 2. `build_config/r2p2-picoruby-ios-sim.rb`
`MRuby::CrossBuild`。`conf.cc.command` = `xcrun --sdk iphonesimulator --find clang`、
フラグに `-arch arm64 -isysroot <sim SDK> -mios-simulator-version-min=<min>`、
`conf.cc.host_command` にホスト clang（mrbc / compiler をホスト用に build）。gembox は
**core + stdlib ＋ compiler gems のみ**（POSIX / shell / networking は iOS サンドボックス
で不安定なので外す）。identity macro は `PICORB_PLATFORM_DARWIN` 系を踏襲。

### 3. `bridge/picoruby_bridge.{h,c}`
C 関数 `char *picoruby_eval(const char *src)`。VM 初期化 → `mrc_load_string_cxt` で
コンパイル → `mrc_create_task` + `mrb_task_run` で実行（`picoruby-bin-picoruby` の
経路を踏襲）→ 実行中の stdout/stderr を fd リダイレクト（temp file）で捕捉し malloc
文字列で返す（Swift 側で free）。コンパイルエラー（`cc->diagnostic_list`）・実行時例外
（`mrb->exc` → `mrb_print_error`）も捕捉文字列に含めアプリは落とさない。

### 4. `app/`（SwiftUI アプリ ＋ xcodegen）
`ContentView`（`TextEditor` 入力欄、Run ボタン、出力 `Text`）、`project.yml`
（bridging header 指定、`Vendor/lib/libmruby.a` リンク、`Vendor/include` ヘッダ検索）。
`.xcodeproj` は生成物で gitignore。

## データフロー

入力テキスト（Swift String）→ C 文字列 → `picoruby_eval` → 内部で VM 実行・
stdout/stderr 捕捉 → C 文字列 → Swift String → 出力欄。VM は呼び出しごとに open/close。

## エラーハンドリング（system boundary のみ）

- Ruby 実行時例外 / SyntaxError: ブリッジで捕捉しメッセージを出力文字列に含めて返す。
- それ以外（メモリ確保失敗等の起こりにくい系）には fallback を足さない。

## 受け入れ基準（検証）

- `rake smoke`（host）が `picoruby_eval` の eval ＋ 出力捕捉を検証して PASS。
- `rake ios` がヘッドレスで Simulator にアプリを install / launch する。
- アプリで `puts "hello #{1+2}"` → 画面に `hello 3`。
- `raise "boom"` → 例外メッセージが出力欄に出てアプリは生存。

## 早期に潰すべき技術リスク（実装の最初のステップで検証）

1. **CrossBuild とホストツール**: picoruby のクロスビルドが mrbc / compiler を
   ホスト用に正しく build するか（`host_command` だけで足りるか、host
   `MRuby::Build` 併記が要るか）。pico2 config を実地で確認しつつ最小の iOS CrossBuild
   が `libmruby.a` を吐くことを最初に通す。
2. **iOS で落ちる gem**: core / stdlib のどれかが POSIX 依存でリンク / 実行に失敗
   しないか。失敗したら gembox をさらに削る。
3. **eval API の実体**: `mrc_load_string_cxt` / `mrc_create_task` / `mrb_task_run` が
   `picoruby.h` だけで解決するか。`picoruby-bin-picoruby` の実装をブリッジで踏襲。
