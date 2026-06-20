## このリポジトリ

`R2P2-iOS` は picoruby を iOS（Xcode / xcodebuild / Simulator / 署名）という別建て
build system へ接続する自己完結 harness。R2P2-ESP32（ESP-IDF 軸）と並列の類型で、
薄い・transitional な R2P2-macOS とは異なり恒久的に独立する。R2P2-macOS には依存しない。

責務:
1. `rake check` で iOS build 前提（フル Xcode.app / iOS SDK / xcodegen）を verify
2. iOS 向け build config を保持（`build_config/r2p2-picoruby-ios-sim.rb`）
3. picoruby を `vendor/picoruby` に fetch し `MRUBY_BUILD_DIR=./build` で pristine に
   保ちながら iOS 向け `libmruby.a` を産出、C ブリッジ経由で SwiftUI アプリにリンク

依存 picoruby は `PICORUBY_REPO` / `PICORUBY_REF` で切替（default: upstream master）。
