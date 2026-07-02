# iOS darwin ports / POSIX model — 設計

## 目的

R2P2-iOS で PicoRuby を **iOS 上で根本的に正しく動かす**。場当たりの per-gem 回避でなく、
「iOS は POSIX。一部 posix port .c が iOS 非対応 API を掴む箇所だけを、同一インターフェースの
iOS 実装に差し替える」を**恒久的な機構**として確立する。今後 porting 対象が増えても
（`ports/common` からの切り出しを含め）同じ機構で吸収できる形にする。

## 確定した原則（合意済み）

1. **iOS は POSIX。** `build.posix?` は darwin で **true たるべき**。iOS は macOS と同一 Darwin/XNU。
   サンドボックスは別 OS モデルでなくアクセス制御 policy 層。
2. 真の POSIX プラットフォームでは port は**単一ルート**（各 gem の `ports/posix` + `ports/common`）で動く。
   iOS もこのルートに乗るのが正しい。
3. iOS の逸脱は**プラットフォーム全体でなく、特定 posix port .c が掴む「特定 API」単位**で起きる。
   直すべきは posix?=false（プラットフォーム否定）でなく、**その特定ファイルだけを iOS 実装に差し替える**こと。
4. 差し替えの実体（generic darwin port `.c`）は fork `bash0C7/picoruby` の `ports/darwin/`。
   選択ロジック（どの port を選ぶか・どの platform macro を define するか）は R2P2-iOS の build_config。

## 根本原因（なぜ現状が間違っているか）

port をコンパイルする経路が 2 つあり、思想（arch ごとに ports を切り出す）と食い違う:

- **mruby upstream `lib/mruby/gem.rb`**: `effective_ports`（`conf.ports` の first-match fallback chain）で
  port を選ぶ。これが正しい機構。`conf.ports :darwin, :posix` で「darwin 優先・posix fallback」。
- **picoruby `lib/picoruby/gem.rb`**: `build.posix?` なら `ports/posix` + `ports/common` を**ハードコードで**引く。
  `darwin` を知らない。

ble が自分の `mrbgem.rake` で `if build.darwin?` → `ports/darwin/*.c` を直コンパイルしているのは、
**この loader が darwin を選べないための回避策**。posix?=true にすると両経路が走り、darwin port と
posix port が二重コンパイルされ重複シンボルで link 失敗する。これが「場当たり」の根。

## 設計

### 1. picoruby の port loader を chain 対応にする（fork・generic 修正）

`lib/picoruby/gem.rb#setup_compilers` を「`ports/posix` 固定」から
「**`effective_ports` の first-match（例: darwin → posix）＋ `ports/common`**」へ変える。

- iOS 固有ロジックではなく、**mruby が既に持つ port model に picoruby loader を合わせる generic な正しさの修正**。
  upstream 提案可能。
- 二重コンパイルが消える（各 gem は chain の first-match 1 本 + common のみ）。
- ble の `mrbgem.rake` hack はこの chain に寄せれば将来消せる（本設計の必須範囲外）。

### 2. iOS 固有の選択は R2P2-iOS build_config に置く

base iOS build_config（`r2p2-picoruby-ios-{sim,device}.rb`）に:

- `conf.ports :darwin, :posix`（iOS = darwin 優先・posix fallback）
- `PICORB_PLATFORM_POSIX` と `PICORB_PLATFORM_DARWIN` を**両方** define
- 必要な link flag（例: `-framework Security`）

#### 両マクロ define の安全性（コードで確認済み）

「どちらを優先するか」は 2 軸に分離され、いずれも build_config で悩む必要がない:

| 「どちらを優先」 | 決定者 |
|---|---|
| port 実装ファイル（rng の posix vs darwin 等） | `conf.ports` chain（darwin 優先）← 設計 #1 |
| 共有 src 内の `#if` 枝 | `.c`/`.h` の `#if` 構造 |

共有 src の分岐軸はほぼ全て `#if defined(PICORB_PLATFORM_POSIX)` / `#if !defined(...)` の
**「POSIX か否か」単一軸**（machine, time, socket, mruby, net.h, mbedtls_config…）。
`PICORB_PLATFORM_DARWIN` は共有 src では `ble.c` の独立した `#ifdef` 2 箇所だけ（POSIX と競合する
`#elif` 連鎖が tree に存在しない）。よって両方 define すると、全 `#if POSIX` 枝は一貫して
POSIX 側を選び、`ble.c` の `#ifdef DARWIN` が追加で CoreBluetooth を有効化する。**precedence 衝突なし。**

### 3. darwin port .c は fork `ports/darwin/`

generic darwin 実装（macOS でも再利用可）。posix port と同一インターフェース。

### 4. 今後の porting はこの chain に素直に積む

新たに iOS 非対応 API を掴む posix port が見つかれば、その gem に `ports/darwin/*.c` を足すだけで
chain が拾う。`ports/common` の中に iOS 非対応の前提が紛れていたら、その部分を `ports/darwin` に
切り出す（common からの切り出しも同じ機構で吸収）。

## 影響範囲（全 posix port 監査の事実確定）

### darwin port が要る（posix port が iOS 非対応 API を掴む）

| gem | 該当 API | 状態 |
|---|---|---|
| picoruby-rng | `fopen("/dev/urandom")` | 実装済（fork branch） |
| picoruby-mbedtls | `open("/dev/urandom")`（`mbedtls_hardware_poll`） | 実装済 |
| picoruby-io-console | `termios` / `tcgetattr` / `tcsetattr`（TTY） | 実装済 |
| **picoruby-machine** | **`gethostuuid()` + `<uuid/uuid.h>`**（macOS 専用・iOS 非存在） | **未実装（新規）** |

### posix port のまま iOS で動く（darwin port 不要）

- `adc / env / gpio / pwm / uart`: stdlib と picoruby 内部 include のみ（HAL stub）。OS 依存 API なし。
- `net`: BSD socket（`sys/socket`, `netdb`, `arpa/inet`）+ mbedtls。posix?=true で mrbgem.rake の
  posix 分岐を選び LwIP/cyw43 を引かない。**当初の #4 問題は posix?=true で消える。**
- `require`: `uname()`（`<sys/utsname.h>`）。iOS で動作。

### 要・別判断（本設計の scope 外）

- `picoruby-socket`: BSD socket は OK だが `#include <openssl/ssl.h>`＝システム OpenSSL 依存
  （iOS 標準に無い）。かつ `add_conflict 'picoruby-socket'` で net と排他。REPL に socket を
  入れないなら無関係。入れるなら別案件。

### 別軸の確認事項（実装フェーズの前提チェック）

posix?=true にすると **mrbgem.rake 内の `if build.posix?` 分岐**も全 gem で発火する
（shell / machine / mruby / require / yaml / net / editor / ble が `posix?` 参照）。
port `.c` の監査とは別軸なので、これらの posix 分岐が iOS で破綻しないかを実装前に確認する。

## 検証

- `rake check` で iOS build 前提（フル Xcode / iOS SDK / xcodegen）を verify。
- base iOS build_config（posix?=true・chain 化 loader）で **二重シンボルなく** iOS sim build が通る。
- 対象 gem の symbol 検証: darwin port が選ばれ posix 版シンボルが除外される
  （`_rng_random_byte_impl` 等が darwin 由来のみ）。
- 完了基準: iOS sim build が通り、machine 含む対象 gem が REPL から呼べる。

## fork への push

fork branch はローカルのみ。**push / branch 作成 / PR は user 確認必須**（CLAUDE.md）。
