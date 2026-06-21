## このリポジトリ

`R2P2-iOS` は picoruby を iOS（Xcode / xcodebuild / Simulator / 署名）という別建て
build system へ接続する自己完結 harness。R2P2-ESP32（ESP-IDF 軸）と並列の類型で、
薄い R2P2-macOS とは異なり恒久的に独立する。R2P2-macOS には依存しない。

責務:
1. `rake check` で iOS build 前提（フル Xcode.app / iOS SDK / xcodegen）を verify
2. iOS 向け build config を保持（`build_config/r2p2-picoruby-ios-sim.rb`）
3. picoruby を `vendor/picoruby` に fetch し `MRUBY_BUILD_DIR=./build` で pristine に
   保ちながら iOS 向け `libmruby.a` を産出、C ブリッジ経由で SwiftUI アプリにリンク

依存 picoruby は `PICORUBY_REPO` / `PICORUBY_REF` で切替（default: upstream master）。

## 関係 repo と ports モデル

`picoruby` repo は PicoRuby の共通コア（rp2040 がプライマリ）。各 mrbgem は
`mrbgems/<gem>/ports/<arch>/`（rp2040 / posix / esp32 / darwin …）にアーキ依存実装を
分けて持つが、**インターフェース（`include/*.h`）は全 port で完全に同一**。
`R2P2-ESP32` / `R2P2-macOS` / `R2P2-iOS` は各アーキの build/flash 依存を格納する repo。

**R2P2-iOS の役割は iOS 向け port を選択する build-config を持つこと**（削る = pruning
ではない）。例: picoruby-ble は darwin/CoreBluetooth port が rp2040(cyw43/btstack) transport
の drop-in 代替。iOS では darwin port を選び、rp2040 専用の `cyw43` や、darwin code path が
参照しない `mbedtls`/`rng` の transitive 依存は引かない。

**iOS 固有のもの（port 選択ロジック・`darwin?` 述語・新規 iOS port の `.c`）は R2P2-iOS 側
（build_config / `ports/ios/`）に置く。upstream fork（`picoruby/picoruby` 及びその fork
`bash0C7/picoruby`、vendor/picoruby）には絶対 commit しない。**

## build-config の scope（core と example）

base の iOS build-config（`build_config/r2p2-picoruby-ios-{sim,device}.rb`）は REPL が要する
最小 VM（reduced gem set、POSIX なし）に留める。**特定 example だけが要る gem（BLE 等）は
example 専用の build-config に置く**。共有 base に example 依存を足すと、その gem を使わない
他 example（REPL）の app link が未解決シンボルで壊れる。
