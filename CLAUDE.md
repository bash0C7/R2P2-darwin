## このリポジトリ

`R2P2-darwin` は PicoRuby を Apple プラットフォーム（macOS host native / iOS cross /
watchOS cross）で build・実行する harness。picoruby/picoruby の fork ではなく独立 repo。
R2P2-ESP32（ESP-IDF 軸）と並列の類型で、Apple の build system（Xcode / xcodebuild /
Simulator / 署名、および macOS host の clang + Swift）を picoruby に接続する。

責務:
1. `rake check` で iOS/watchOS build 前提（フル Xcode.app / SDK / xcodegen）を verify、
   `rake macos:check` で macOS host 前提（Xcode CLT / brew openssl@3 / Swift）を verify
2. build config を保持 — iOS/watchOS 向け cross build config（`build_config/r2p2-picoruby-ios-repl-{sim,device}.rb`
   ほか example ごとの `r2p2-picoruby-ios-<example>-{sim,device}.rb`、`r2p2-picoruby-watchos-{sim,device}.rb`）と
   Darwin host build config
3. picoruby を `vendor/picoruby` に fetch し `MRUBY_BUILD_DIR=./build` で pristine に
   保ちながら、各 platform の `libmruby.a`（C ブリッジ経由で SwiftUI アプリにリンク）や
   macOS host の `r2p2` / `picoruby` runner を産出。`MRUBY_BUILD_DIR=./build` は
   `cd vendor/picoruby && rake` 実行時の cwd 相対のため、実体は
   repo 直下の `R2P2-darwin/build/`（`vendor/picoruby/build/` ではない）。
   クリーンビルドで stale object を除去する際は repo 直下 `build/<target>/` を消す

依存 picoruby は `PICORUBY_REPO` / `PICORUBY_REF` で切替（default: fork
`bash0C7/picoruby` の `port-darwin` branch — ble/rng/mbedtls/io-console/machine/socket の
darwin port と hal-io-darwin を統合した branch）。upstream
`picoruby/picoruby` の master にはこれらの darwin port が無く、REPL/networking
example が要る `conf.ports :darwin, :posix` の fallback 先が壊れるため、upstream
を指すと動かない example が出る。fork は master を内包した完全な tree なので
別の fork/branch の組にそのまま差し替えてもよく、vendor を特定 ref に固定する規則
ではない（`PICORUBY_REF` を変えれば vendor 全体がその ref になる）。`pristine` は
build 生成物を vendor に混ぜない・vendor へ commit しない意であって、指す ref を
縛るものではない。fork 側で darwin port を複数 branch に分けて作業した場合、
push 前に `PICORUBY_REF` が指す branch へ**必ず統合する**こと — 別 branch に分岐
したまま片方だけを `PICORUBY_REF` に据えると、もう片方の修正が vendor に反映
されない。

## 関係 repo と ports モデル

`picoruby` repo は PicoRuby の共通コア（rp2040 がプライマリ）。各 mrbgem は
`mrbgems/<gem>/ports/<arch>/`（rp2040 / posix / esp32 / darwin …）にアーキ依存実装を
分けて持つが、**インターフェース（`include/*.h`）は全 port で完全に同一**。
R2P2-darwin は Apple 各ターゲットの build 依存を格納する repo で、Apple 向け port を
選択する build-config を持つ（削る = pruning ではない）。例: picoruby-ble は
darwin/CoreBluetooth port が rp2040(cyw43/btstack) transport の drop-in 代替。iOS では
darwin port を選び、rp2040 専用の `cyw43` は gem 自身の `unless build.darwin?` で外れる。
`picoruby-mbedtls` / `picoruby-rng` の transitive 依存は**外さない** — `ble.rb` は boot で
`require 'mbedtls'` し GATT database hash に `MbedTLS::CMAC` を使うので、config で
`spec.dependencies.reject!` すると BLE の Ruby 層が丸ごと読み込まれない（`BLE.new` が
`wrong number of arguments` で落ちる）。両 gem の darwin port は iOS で build でき、app 側は
`-framework Security`（`SecRandomCopyBytes`）を link する。

置き場所の線引き:
- picoruby の gem に属するもの（各 gem の `ports/darwin/`、`darwin?` 述語、port loader）は
  fork `bash0C7/picoruby` の `port-darwin` に置く。編集は clone
  `~/dev/src/github.com/bash0C7/picoruby` から `port-darwin` の worktree を切って行う
  （`git worktree add .claude/worktrees/port-darwin port-darwin`）。commit は `port-darwin` に
  直接、topic branch は作らない。push は user 承認。検証は
  `PICORUBY_REPO=/Users/bash/dev/src/github.com/bash0C7/picoruby PICORUBY_REF=port-darwin rake refresh`
  で未 push の commit を vendor に流し込んでから R2P2-darwin 側の rake で行う
- Apple の build 選択（build_config）、C ブリッジ、example 固有 gem（`examples/ios/<name>/picoruby-*`）、
  SwiftUI アプリは R2P2-darwin に置く
- `vendor/picoruby` には commit しない。upstream `picoruby/picoruby` へは本 repo から push も PR も
  しない（fork 側の責務）
- `port-darwin` は upstream master に対して常に behind 0 を保つ。upstream の変更で本 repo の build が
  壊れたら、古い SHA に pin して逃げるのではなく、本 repo（build_config / bridge / project.yml）と
  fork の darwin port を upstream に合わせて直す。影響範囲の大きさは回避の理由にならない

## Platform model — darwin は POSIX ファミリー

upstream picoruby は `PICORB_PLATFORM_POSIX` を「libc / thread / fd / signal を持つ OS 上で動く」
という能力クラスの印として使い、その無い build には MCU 向けの port 契約（hwclock、GPIO sleep、
littlefs / watchdog、`sigint_status` の port 側 storage）を要求する。iPhone / Apple Watch / Mac は
すべて Darwin（XNU + BSD libc）なので POSIX クラスに属する。したがって:

- **本 repo の build config は macOS host / iOS / watchOS すべてで `PICORB_PLATFORM_POSIX` と
  `PICORB_PLATFORM_DARWIN` を両方定義する。** VM を小さくする目的で POSIX を外すのは不整合を生む
  最適化であり採らない
- Apple 固有の差分（CoreBluetooth、`SecRandomCopyBytes`、tty 無し、sandbox 下の `/dev/urandom`、
  bridge が持つ task HAL）は `PICORB_PLATFORM_DARWIN` + `conf.ports :darwin, :posix` +
  example 固有 gem で吸収する。darwin port を持つ gem は darwin が、持たない gem は posix が選ばれる
- `conf.ports :darwin, :posix` は config block 内のどこに書いても効く。port dir の選択は config 評価後の
  `gems.setup`（vendor の `Rakefile`）で各 gem の `setup` が `effective_ports` を first match で読む
  ときに決まり、`conf.gem` は spec を登録するだけで `setup` を呼ばない。置き場所は読み手のための
  規約で、`picoruby-machine` の `conf.gem` に隣接させる
- `picoruby-machine` は reduced config でも明示的に追加する。Estalloc heap glue
  （`mrb_basic_alloc_func` / `mrb_open_with_custom_alloc`）がこの gem にあり、upstream は
  `gembox "core"` 経由で常に含めている
- CrossBuild では first match により darwin port だけが compile されるので、**fork の
  `ports/darwin/` は posix port が提供する symbol をすべて自前で提供する（自己完結）**。
  `rake smoke` は host で `ports/darwin/machine.c` を exercise し、device SDK 固有の破損（SDK が禁止する
  API）は `rake ios:<name>:device:check` / `rake watchos:led:device:check` が捕まえる。唯一の例外は
  mruby VM の task HAL（`mrb_hal_task_init` / `final` / `idle_cpu` / `sleep_us`、`mrb_task_enable_irq` /
  `disable_irq`）で、これは host では mruby-task の posix port、iOS/watchOS では `bridge/task_hal_ios.c`
  が持つ。cross build の archive にも mruby-task の posix `task_hal.o` は入っており、bridge がこの
  6 symbol を**全部**定義しているから member が引かれず二重定義にならない — upstream が HAL entry を
  足したら bridge にも足す。darwin port の `hal.c` がこれを定義してはいけないのも同じ理由
- gem の `ports/darwin/ext/` は Swift package（`picoruby-ble` は自分の mrbgem.rake で `swift build`、
  example gem のものは Xcode が app link 時に build）。fork の `lib/picoruby/gem.rb` は POSIX の
  port glob からこの subtree を除外する — darwin port に C source を足すときは `ext/` の外に置く
- watchOS（と tvOS）の SDK は `fork` / `exec` を禁止するので、POSIX で入る `mruby-io` の posix HAL
  （`IO.popen` 用）がそのままでは compile できない。mruby-io は upstream mruby の submodule なので
  触らず、mruby の外部 HAL provider 規約（`hal-<short>-<conf>` 名の gem が port object を置き換える）で
  fork の `hal-io-darwin` gem を watchOS config に `conf.gem core: "hal-io-darwin"` で入れる。
  iOS / macOS では不要（posix HAL のまま）
- POSIX では `picoruby-mruby` が `mruby-io`（`puts` / `print` の提供元）を依存に足し（`mruby-task` は
  常に依存）、`MRB_BASELINE_PROFILE=1` を build-wide に定義する。非 POSIX なら代わりに
  `MRB_CONSTRAINED_BASELINE_PROFILE=1` + `MRB_HEAP_PAGE_SIZE=128`。config に profile define を
  手書きしない（POSIX と矛盾する）
- define parity: `examples/*/*/project.yml` の `GCC_PREPROCESSOR_DEFINITIONS` と `Rakefile` の smoke
  defines は build config が実際に渡す define（上記 `MRB_BASELINE_PROFILE=1` を含む）と一致させる。
  `sizeof(mrb_state)` に効く define の不一致は bridge と lib の間でメモリ破壊になる。確認は
  `cd vendor/picoruby && rake -v` の build log（compile command が出る）から `-D` を抽出して突合する。
  watchOS の `build_config/recompile_arm64_32.rb` は config file の define に gem が足す build-wide
  define を加えて再 compile する — `picoruby-mruby/mrbgem.rake` を変えたらここも追従

## build-config の命名規約と scope

build config は picoruby 命名規約 `r2p2-<runtime>-<target>.rb`（upstream の `r2p2-picoruby-pico2.rb`
等と同列）に沿う。target は cross build の SDK 軸（`ios-*` / `watchos-*`）または
Darwin host（`darwin` / `darwin-ble` / `darwin-single`）。

**core と example の scope**: `repl` / `networking` の base iOS build-config
（`r2p2-picoruby-ios-repl-{sim,device}.rb` / `r2p2-picoruby-ios-net-{sim,device}.rb`）は
full-REPL gembox（`mruby-posix` + `core` + `stdlib` + `shell`）を使う。`virtual-peripheral` /
`iphone-torch` / `stackchan` / `tilt-synth` / `led-toggle`（`examples/watchos/led-toggle`）は
reduced gem set（`conf.picoruby` + `mruby-compiler` + `picoruby-machine`、gembox 無し）を base に、
それぞれが要る gem（BLE 等）だけを **example 専用の build-config に置く**。どちらも
`PICORB_PLATFORM_POSIX` + `PICORB_PLATFORM_DARWIN` + `conf.ports :darwin, :posix`
（下記 Platform model）。共有 base に example 固有の依存を足すと、その gem を使わない他 example の
app link が未解決シンボルで壊れる。

**Darwin host base + ble opt-in**: `r2p2-picoruby-darwin.rb` は Darwin host base
（`PICORB_PLATFORM_DARWIN` を立て、汎用 POSIX ではなく Darwin host build として compile）。
`r2p2-picoruby-darwin-ble.rb` は base + `picoruby-ble` + `picoruby-picotest` opt-in
（CoreBluetooth は Darwin にしか無いため）。`r2p2-picoruby-darwin-single.rb` は base から
REPL/shell bin を落とした single-binary 用。

## macos: namespace（host-side harness）

`rakelib/macos.rake` の `namespace :macos` は macOS host build の薄い harness:
前提 check（`macos:check`）+ Darwin host build config + `vendor/picoruby` を pristine に
保つ薄い rake wrapper（`macos:build` / `macos:run` / `macos:single`）で構成する。
picoruby/picoruby が Darwin host 用 build config を取り込めば macOS host 部分は役目を
終える（PR 経路は picoruby fork 側、本 repo からは PR しない）。

`r2p2-picoruby-darwin-ble.rb` で `macos:build` したバイナリは、CoreBluetooth API を
叩いた瞬間に macOS TCC が `SIGABRT` で落とす — LaunchServices 経由でアプリバンドル
（`NSBluetoothAlwaysUsageDescription` 入り Info.plist）から起動された process 以外は、
署名済み・許可済みでも例外なく落ちる。本 repo はバイナリを生成するだけで bundle 化は
利用側（例: stackchan-picoruby の `pc/stackchan-pico`、`rake pc:app_bundle` + `open -a`）
の責務。macos.rake にバンドル化タスクを足す必要はない。

## Session の役割分担（model tiering）

本 repo の作業は 3 層で回す。理由: build / clone / 署名の log は長く、main context に流し込むと判断の
質が落ちる。決定論的な実行と log の読解は安い model で十分であり、高い model は判断に使う。

- **決定論的なコマンド実行は haiku の subagent に委譲する**: build、install、`rake refresh`、
  tmux での長尺 job の起動と完了待ち、script による file 書換え、git の plumbing。prompt には
  実行するコマンドを verbatim で渡し、raw output をそのまま返させる。解釈・要約・改変をさせない
- **log と証拠の解釈は sonnet の subagent に委譲する**: build log / link error / test 出力 /
  `git log` の読解。事実と推論を分けて報告させ、推奨は求めない
- **Fable（main）は制御に専念する**: 何を実行するかの決定、report の吟味（「成功」を鵜呑みにせず
  tool 結果と突合）、scope と plan の管理、user との対話。自分で長い log を読まない
- 進捗報告は必ず tool 結果に紐づける。未検証のものは未検証と書く。失敗は出力付きでそのまま報告する
- device 系 rake（`ios:*:device:*` / `watchos:*:device:*`）を tmux や subagent から回すときは
  UTF-8 locale（`LANG`）と Ruby version（`RBENV_VERSION`）を command 側で明示する。端末名に
  非 ASCII 文字があると `devicectl` / `xcodebuild -showdestinations` の出力に対する Rakefile の
  regex が `invalid byte sequence` で落ちる
