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
   macOS host の `r2p2` / `picoruby` runner を産出

依存 picoruby は `PICORUBY_REPO` / `PICORUBY_REF` で切替（default: fork
`bash0C7/picoruby` の `port-darwin` branch — ble/rng/mbedtls/io-console/machine の
darwin port と picoruby-net の POSIX allocator fix を統合した branch）。upstream
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
darwin port を選び、rp2040 専用の `cyw43` や、darwin code path が参照しない
`mbedtls`/`rng` の transitive 依存は引かない。

**Apple 固有のもの（port 選択ロジック・`darwin?` 述語・新規 port の `.c`）は R2P2-darwin 側
（build_config / `ports/ios/` など）に置く。upstream fork（`picoruby/picoruby` 及びその fork
`bash0C7/picoruby`、vendor/picoruby）には絶対 commit しない。**

## build-config の命名規約と scope

build config は picoruby 命名規約 `r2p2-<runtime>-<target>.rb`（upstream の `r2p2-picoruby-pico2.rb`
等と同列）に沿う。target は cross build の SDK 軸（`ios-*` / `watchos-*`）または
Darwin host（`darwin` / `darwin-ble` / `darwin-single`）。

**core と example の scope**: `repl` / `networking` の base iOS build-config
（`r2p2-picoruby-ios-repl-{sim,device}.rb` / `r2p2-picoruby-ios-net-{sim,device}.rb`）は
POSIX を有効化した full-REPL gembox（`mruby-posix` + `core` + `stdlib` + `shell`、
`conf.ports :darwin, :posix`）を使う。`virtual-peripheral` / `iphone-torch` /
`led-toggle`（`examples/watchos/led-toggle`）は reduced gem set（POSIX なし）のまま、
それぞれが要る gem（BLE 等）だけを **example 専用の build-config に置く**。共有 base に
example 固有の依存を足すと、その gem を使わない他 example の app link が未解決シンボルで壊れる。

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
