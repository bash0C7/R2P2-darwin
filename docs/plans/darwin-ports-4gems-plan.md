# 実行プラン: darwin ports 4 mrbgems 開発 (ble 先行実装に準拠)

## Ground truth (机上プランの誤りを訂正)

旧プランは「darwin port を R2P2-iOS 側 (`ports/ios/`) に置き fork には commit しない」としていたが**誤り**。
**事実は picoruby-ble**: darwin port は **fork `bash0C7/picoruby` の `mrbgems/<gem>/ports/darwin/` に commit して動いている**。
4 gem も同じ形に従う。

確定事項:
- `vendor/picoruby` は fork `bash0C7/picoruby` の checkout。Rakefile default `PICORUBY_REF=picoruby-ble-darwin-port`。R2P2-iOS では gitignore 対象。
- ble の darwin port は fork 内 `mrbgems/picoruby-ble/ports/darwin/{ble,ble_central,ble_peripheral}.c` 等。
- iOS cross-build の port 選択機構:
  - build_config で `conf.ports :darwin` → `lib/mruby/gem.rb` が各 gem の `ports/darwin/*.c` を自動 glob (effective_ports)。
  - `build.darwin?` は build_config で **false に monkeypatch**。mrbgem.rake 内 `if build.darwin?` ブロック（Swift dylib build 等、host macOS 用）は iOS cross-build では走らない。
  - ble は Swift backend(CoreBluetooth) を要すが、**rng/mbedtls は Swift 不要** — `ports/darwin/*.c` を置き、Security.framework を build_config の linker flag で繋ぐだけ。
- example-scoped: 各 gem を要する example 専用 build_config に gem 追加。base(REPL) config は触らない。

## 対象 (B 分類: darwin 固有 API が genuine に必要なもの)

| issue | gem | darwin port 内容 | Swift要否 | 難度 |
|---|---|---|---|---|
| #1 | picoruby-rng | `/dev/urandom` → `SecRandomCopyBytes` (Security.framework) | 不要 | 小(<10行) |
| #2 | picoruby-mbedtls | `mbedtls_hardware_poll` を `SecRandomCopyBytes` に。`timing_alt` の `clock_gettime` は維持 | 不要 | 小 |
| #3 | picoruby-io-console | macOS=termios 流用 / iOS=no-TTY stub の platform 分岐 | 不要 | 中 |
| #4 | picoruby-net (TLS) | route1: #2 解決で既存 mbedTLS TLS client が動く確認のみ。route2(Network.framework) は ATS 必須化まで保留 | (route2のみ要) | 大(条件付) |

## 開発場所と landing

darwin port の .c は **fork `bash0C7/picoruby`** に置く（ble と同じ）。`vendor/picoruby` 内で編集 → fork へ commit/push → R2P2-iOS は `rake refresh` で取得。
**fork への push / branch 作成 / PR は user 確認必須**（CLAUDE.md）。branch 戦略（既存 `picoruby-ble-darwin-port` に足すか gem 別 branch か）は未決定 → user に確認。

## 依存順 2 波

```
第1波(並列): [#1 rng]  [#3 io-console]
第2波: [#2 mbedtls]  ← #1 の SecRandomCopyBytes link 方法を流用
第3波: [#4 net-TLS]   ← route1: #2 entropy 修正済み前提で TLS client 動作確認
```

## 実装状況

- **#1 rng** 完了・検証済 — fork branch `rng/darwin-port`、`r2p2-picoruby-ios-rng-sim.rb`。libmruby.a に `_rng_random_byte_impl`=T、posix 除外を確認。
- **#2 mbedtls** 完了・検証済 — fork branch `mbedtls/darwin-port`（rng から分岐）、`...-mbedtls-sim.rb`。Mbed-TLS v3.6.2 ごと iOS sim build 通過。
- **#3 io-console** 完了・検証済 — fork branch `io-console/darwin-port`、`...-io-console-sim.rb`。iOS sim で termios 参照ゼロ。
- **#4 net-TLS** 設計上ブロック（darwin port のみでは不可）。理由: net の mrbgem.rake は実装選択を `if build.posix? ... else (LwIP) end` で行い **conf.ports 機構を使わない**。darwin では else 分岐に落ち、gem load 時に **LwIP を git clone** し cyw43/lwip 前提の src を組む。これを darwin 向けに直すには net の mrbgem.rake / net.h（共有 interface）の編集が必須だが、それは **darwin port（`ports/darwin/*.c`）ではない fork 改変**であり原則違反。よって #4 は net 側 upstream が ports 機構対応（darwin/posix を ports で選べる構造）に変わるのが前提。#1〜#3 はクリーンな darwin port のみで成立し、この依存はない。
  - 補足: dep の picoruby-pack は mrubyc 専用で mruby VM では `src/mruby/pack.c` 欠落により単体でも fatal（iOS 限定でなく全 mruby-VM build の問題）。これも net upstream 側の課題。

全 fork branch はローカルのみ・push 未実施。R2P2-iOS 側は branch `feat/darwin-ports-4gems`。

## 各 gem の根拠ファイル (posix port — darwin port の写経元)

- `vendor/picoruby/mrbgems/picoruby-rng/ports/posix/rng.c` (`rng_random_byte_impl`)
- `vendor/picoruby/mrbgems/picoruby-mbedtls/ports/posix/timing_alt.c` (`mbedtls_hardware_poll`)
- `vendor/picoruby/mrbgems/picoruby-io-console/ports/posix/io-console.c`
- `vendor/picoruby/mrbgems/picoruby-net/ports/posix/tls_client.c`

## 検証

- `rake check` で iOS build 前提を verify。
- 完了基準: iOS sim build が通り、対象 gem の機能が REPL から呼べる。
- `Security.framework` link が #1 #2 で必要。
- iOS sandbox が壊すのは `/dev/urandom` 直接 open(#1 #2) と termios/TTY(#3)。この 2 系統が darwin port を genuine に正当化する根拠（ble の CoreBluetooth と同類型）。
