# iOS POSIX port-chain モデル 実装プラン

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** iOS=POSIX を恒久機構として確立する。picoruby の port loader を `effective_ports` chain 対応にし、`conf.ports :darwin, :posix` + posix?=true で「darwin port があれば darwin、無ければ posix」を二重コンパイルなく成立させ、rng/mbedtls/io-console/machine の 4 darwin port で end-to-end 実証する。

**Architecture:** fork `bash0C7/picoruby`（`vendor/picoruby`）の `lib/picoruby/gem.rb` を first-match port 選択に修正（generic 修正）。machine の darwin port を新規追加。R2P2-iOS の build_config が `conf.ports :darwin,:posix` と `PICORB_PLATFORM_POSIX`/`PICORB_PLATFORM_DARWIN` 両 define で iOS を posix ルートに乗せる。検証＝libmruby.a を build し `nm` で「darwin port のシンボルのみ・posix 版が除外」を確認する。

**Tech Stack:** PicoRuby/mruby cross-build（Ruby DSL build_config）、clang（iphonesimulator SDK）、`nm`/`ar`、git worktree。

**Scope:** 本プランは port-chain モデルの実証に限定する。**full-REPL gembox（core/stdlib 全 gem）を posix?=true で iOS に通す移行は別プラン**。本プランは 4 darwin-port gem の最小 build_config で機構の正しさを確定する。

---

## Branch / Worktree 戦略（revert 容易・2 repo）

2 つの git repo が絡む。fork は固定パス（`vendor/picoruby`）でしか build できない（worktree は生成ヘッダを欠く）。R2P2-iOS では `/vendor/` が gitignore。これを踏まえた revert-first 戦略：

- **fork（`vendor/picoruby`）= branch で隔離**。pristine な `picoruby-ble-darwin-port` を温存し、作業は新 branch `ios-posix-model`（base = `io-console/darwin-port`、これに rng+mbedtls+io-console の darwin port が積層済み）で行う。**revert lever = `git -C vendor/picoruby switch picoruby-ble-darwin-port`**（pristine build へ即復帰）。risky な loader 修正は単独 commit にし、必要なら `git revert <sha>` で単体撤回可能。
- **R2P2-iOS = worktree で隔離**。`.claude/worktrees/ios-posix-model`（branch `feat/ios-posix-model`）。build は固定パスの fork を共有するため worktree 内 `vendor` を実体へ symlink。**revert lever = `git worktree remove`**。
- fork branch はローカルのみ。**push/PR は user 確認必須**。

---

## File Structure

- `vendor/picoruby/lib/picoruby/gem.rb`（Modify）— port loader を `effective_ports` first-match + common に。唯一の構造変更。
- `vendor/picoruby/mrbgems/picoruby-machine/ports/darwin/machine.c`（Create）— posix port のコピー＋`Machine_get_unique_id` を iOS 対応に差し替え。
- `build_config/r2p2-picoruby-ios-portchain-sim.rb`（Create, R2P2-iOS）— 4 gem で chain モデルを実証する最小 sim config。

---

## Task 0: Worktree / branch セットアップ

**Files:** なし（git 操作のみ）

- [ ] **Step 1: fork に統合 branch を作る（rng+mbedtls+io-console 積層済みを base に）**

Run:
```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-iOS/vendor/picoruby
git switch -c ios-posix-model io-console/darwin-port
git ls-tree -r --name-only HEAD | grep -E 'ports/darwin/(rng|timing_alt|io-console)\.c'
```
Expected: `picoruby-rng/ports/darwin/rng.c`, `picoruby-mbedtls/ports/darwin/timing_alt.c`, `picoruby-io-console/ports/darwin/io-console.c` の 3 行が出る。

- [ ] **Step 2: R2P2-iOS に worktree を作り vendor を共有 symlink**

Run:
```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-iOS
git worktree add .claude/worktrees/ios-posix-model -b feat/ios-posix-model
ln -s ../../vendor .claude/worktrees/ios-posix-model/vendor
ls -l .claude/worktrees/ios-posix-model/vendor
```
Expected: symlink が `../../vendor` を指す（worktree の build が固定パスの fork を共有）。

- [ ] **Step 3: Commit（worktree 側は変更なし。fork branch 作成のみで commit 不要）**

このタスクに commit はない（branch/worktree 作成のみ）。次タスクから worktree（`.claude/worktrees/ios-posix-model`）で作業する。

---

## Task 1: picoruby port loader を chain 対応にする（fork・最重要・単独 commit）

**Files:**
- Modify: `vendor/picoruby/lib/picoruby/gem.rb:9-19`

- [ ] **Step 1: 現状を確認（テスト相当：現状は posix ハードコード）**

Run:
```bash
sed -n '7,20p' /Users/bash/dev/src/github.com/bash0C7/R2P2-iOS/vendor/picoruby/lib/picoruby/gem.rb
```
Expected: `["posix", "common"].each do |subdir|` が見える（darwin 非対応）。

- [ ] **Step 2: loader を first-match + common に書き換え**

`vendor/picoruby/lib/picoruby/gem.rb` の `setup_compilers` 内、`return unless cc.build.posix?` 以降のブロックを次に置換：

```ruby
        return unless cc.build.posix?
        # setup for POSIX (and POSIX-family ports selected via conf.ports).
        # Pick the first port dir present in effective_ports (e.g. darwin then
        # posix). Fall back to "posix" so host posix builds (effective_ports
        # => ["posix"]) and builds that don't set conf.ports are unchanged.
        platform_port =
          build.effective_ports.find { |p| Dir.exist?("#{dir}/ports/#{p}") } || "posix"
        [platform_port, "common"].each do |subdir|
          Dir.glob("#{dir}/ports/#{subdir}/**/*.c").each do |src|
            obj = objfile(src.pathmap("#{build_dir}/ports/#{subdir}/%n"))
            build.libmruby_objs << obj
            file obj => src do |f|
              cc.run f.name, f.prerequisites.first
            end
          end
        end
```

- [ ] **Step 3: 既存 host posix build が壊れないことを reasoning で確認（regression gate）**

`effective_ports` は CrossBuild 以外で `["posix"]` を返す（`lib/mruby/build.rb:207`）。host posix build は `ports/posix` を持つので first-match=posix。`conf.ports` 未設定の CrossBuild は `[]` → `|| "posix"` で従来通り。`darwin` port を持つ gem だけ chain で darwin を選ぶ。二重コンパイルは起きない（posix と darwin の両方を足す経路が無くなった）。

- [ ] **Step 4: Commit（risky 修正を単独で）**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-iOS/vendor/picoruby
git add lib/picoruby/gem.rb
git commit -m "fix(port-loader): select first matching port from effective_ports

picoruby loader hardcoded ports/posix; honor conf.ports chain
(e.g. darwin then posix) so a gem's darwin port replaces its posix
port without double-compiling. Falls back to posix when unset."
```

---

## Task 2: machine の darwin port を追加（fork）

**Files:**
- Create: `vendor/picoruby/mrbgems/picoruby-machine/ports/darwin/machine.c`

iOS で動かないのは posix port の `Machine_get_unique_id` 内 `gethostuuid()` のみ（macOS 専用）。他（pthread reader / poll / nanosleep / clock_gettime）は iOS 対応。darwin port は posix port の**全関数を維持**し、`Machine_get_unique_id` だけを iOS 対応に差し替える（chain は posix の代わりに darwin を選ぶため、全シンボルを darwin 側が供給する必要がある）。

- [ ] **Step 1: posix port をコピーして darwin port の土台を作る**

Run:
```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-iOS/vendor/picoruby/mrbgems/picoruby-machine
mkdir -p ports/darwin
cp ports/posix/machine.c ports/darwin/machine.c
```

- [ ] **Step 2: `<uuid/uuid.h>` include を削除**

`ports/darwin/machine.c` の先頭付近、次の 3 行を削除：
```c
#ifdef __APPLE__
#include <uuid/uuid.h>
#endif
```

- [ ] **Step 3: `Machine_get_unique_id` を iOS 対応実装に置換**

`ports/darwin/machine.c` の `Machine_get_unique_id` 関数全体を次に置換（`gethostuuid` を使わない。iOS sandbox では UIKit `identifierForVendor` 抜きに安定 ID を C だけで取得する API が無いため、ID 利用不可を honest に返す。安定 ID が要件化したら ble と同型の Swift backend port で後置可能）：

```c
bool
Machine_get_unique_id(char *id_str)
{
  /* iOS provides no C-only stable unique id (gethostuuid is macOS-only;
   * a stable per-vendor id requires UIKit identifierForVendor). Report
   * unavailable rather than fabricating one. A Swift-backed darwin port
   * (cf. picoruby-ble) can supply identifierForVendor later if needed. */
  (void)id_str;
  return false;
}
```

- [ ] **Step 4: machine の posix シンボルを引かず darwin が選ばれることを build で確認**

Run（worktree から、machine を含む chain build。machine は io-console に依存するため両 gem を含む最小 config を一時利用する → Task 4 で恒久 config 化。ここでは Task 4 の config 作成後に再検証してよいので、まず構文確認のみ）：
```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-iOS/vendor/picoruby
xcrun --sdk iphonesimulator clang -fsyntax-only \
  -DPICORB_PLATFORM_POSIX -DPICORB_PLATFORM_DARWIN -DPICORB_VM_MRUBY -DMRB_INT64 -DMRB_NO_BOXING \
  -I mrbgems/picoruby-machine/include -I mrbgems/picoruby-mruby/include \
  -I mrbgems/picoruby-io-console/include -I include \
  mrbgems/picoruby-machine/ports/darwin/machine.c && echo SYNTAX_OK
```
Expected: `SYNTAX_OK`（include パス不足で失敗する場合は不足ヘッダを `-I` 追記。フル build は Task 5 で行う）。

- [ ] **Step 5: Commit**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-iOS/vendor/picoruby
git add mrbgems/picoruby-machine/ports/darwin/machine.c
git commit -m "feat(machine): add darwin port (iOS-safe Machine_get_unique_id)

Copy of posix port; drop gethostuuid (macOS-only) and report
unique id unavailable on iOS instead of fabricating one."
```

---

## Task 3: 4 darwin port が統合 branch に揃っていることを確認（fork）

**Files:** なし（確認のみ。rng/mbedtls/io-console は base branch から継承済み、machine は Task 2 で追加）

- [ ] **Step 1: 4 port の存在を確認**

Run:
```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-iOS/vendor/picoruby
for f in picoruby-rng/ports/darwin/rng.c picoruby-mbedtls/ports/darwin/timing_alt.c \
         picoruby-io-console/ports/darwin/io-console.c picoruby-machine/ports/darwin/machine.c; do
  test -f mrbgems/$f && echo "OK  $f" || echo "MISSING  $f"
done
```
Expected: 4 行とも `OK`。

---

## Task 4: chain モデル実証 build_config を作る（R2P2-iOS / worktree）

**Files:**
- Create: `build_config/r2p2-picoruby-ios-portchain-sim.rb`

base sim config（`r2p2-picoruby-ios-sim.rb`）を土台に、posix?=true 化＋chain＋4 gem を加える。

- [ ] **Step 1: config を作成**

`.claude/worktrees/ios-posix-model/build_config/r2p2-picoruby-ios-portchain-sim.rb` を作成：

```ruby
# iOS Simulator port-chain model PoC: posix?=true + conf.ports :darwin,:posix.
# Proves a gem's darwin port replaces its posix port with no double-compile,
# across rng / mbedtls / io-console / machine. Not the REPL base config.

sdk_path = `xcrun --sdk iphonesimulator --show-sdk-path`.strip
clang    = `xcrun --sdk iphonesimulator --find clang`.strip
ar       = `xcrun --sdk iphonesimulator --find ar`.strip
ios_min  = ENV["IOS_MIN"] || "17.0"

MRuby::CrossBuild.new("ios-portchain-sim") do |conf|
  conf.toolchain :clang
  conf.linker.libraries.delete("m")

  conf.cc.command       = clang
  conf.linker.command   = clang
  conf.archiver.command = ar
  conf.cc.host_command  = "clang"

  conf.cc.flags << "-arch" << "arm64"
  conf.cc.flags << "-isysroot" << sdk_path
  conf.cc.flags << "-mios-simulator-version-min=#{ios_min}"

  conf.cc.defines << "MRB_TICK_UNIT=4"
  conf.cc.defines << "MRB_TIMESLICE_TICK_COUNT=3"
  conf.cc.defines << "PICORB_ALLOC_ALIGN=8"
  conf.cc.defines << "PICORB_ALLOC_ESTALLOC"
  conf.cc.defines << "PICORB_PLATFORM_POSIX"   # iOS IS POSIX
  conf.cc.defines << "PICORB_PLATFORM_DARWIN"  # ...and darwin (additive)
  conf.cc.defines << "MRB_INT64"
  conf.cc.defines << "MRB_NO_BOXING"
  conf.cc.defines << "MRB_UTF8_STRING"

  # iOS port selection: darwin first, posix fallback.
  conf.ports :darwin, :posix

  conf.picoruby

  conf.gem core: "mruby-compiler2"

  # The four gems whose posix port reaches an iOS-absent API and thus ship
  # a darwin port. machine depends on io-console.
  conf.gem "#{MRUBY_ROOT}/mrbgems/picoruby-rng"
  conf.gem "#{MRUBY_ROOT}/mrbgems/picoruby-mbedtls"
  conf.gem "#{MRUBY_ROOT}/mrbgems/picoruby-io-console"
  conf.gem "#{MRUBY_ROOT}/mrbgems/picoruby-machine"

  # rng/mbedtls darwin ports use SecRandomCopyBytes.
  conf.linker.flags << "-framework" << "Security"
end
```

- [ ] **Step 2: Commit**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-iOS/.claude/worktrees/ios-posix-model
git add build_config/r2p2-picoruby-ios-portchain-sim.rb
git commit -m "build(ios): add port-chain PoC sim config (posix?=true + darwin ports)"
```

---

## Task 5: build + symbol 検証（このドメインの "test"）

**Files:** なし（build と検証）

- [ ] **Step 1: libmruby.a を chain config で build**

Run（worktree から。vendor symlink 経由で fork `ios-posix-model` を build）：
```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-iOS/.claude/worktrees/ios-posix-model
MRUBY_BUILD_DIR="$PWD/build" \
MRUBY_CONFIG="$PWD/build_config/r2p2-picoruby-ios-portchain-sim.rb" \
  sh -c 'cd vendor/picoruby && rake -j1'
```
Expected: build 成功。**`duplicate symbol` / link error が出ないこと**（chain 修正が効いている証拠）。

- [ ] **Step 2: darwin port のシンボルが採用され posix 版が除外されたことを確認**

Run:
```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-iOS/.claude/worktrees/ios-posix-model
LIB=$(find build -name libmruby.a | head -1)
echo "--- rng: darwin(SecRandomCopyBytes) 採用 / posix(/dev/urandom) 不在 ---"
nm "$LIB" | grep -i SecRandomCopyBytes && echo "(SecRandom 参照あり=darwin)"
echo "--- machine: Machine_get_unique_id は定義済み・gethostuuid 不参照 ---"
nm "$LIB" | grep -i "Machine_get_unique_id\|gethostuuid"
echo "--- io-console: termios 不参照 ---"
nm "$LIB" | grep -i "tcgetattr\|tcsetattr" || echo "(termios 参照なし=darwin port 採用)"
```
Expected: `SecRandomCopyBytes`=U（参照あり）、`gethostuuid` の **U（未定義参照）が無い**、`tcgetattr/tcsetattr` の参照が無い。＝全 gem で darwin port が選ばれ posix 版 API が引かれていない。

- [ ] **Step 3: 二重シンボルが無いことを明示確認**

Run:
```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-iOS/.claude/worktrees/ios-posix-model
LIB=$(find build -name libmruby.a | head -1)
for sym in _rng_random_byte_impl _mbedtls_hardware_poll _Machine_get_unique_id; do
  cnt=$(nm "$LIB" | grep -c " T $sym$")
  echo "$sym : T 定義数 = $cnt（期待 1）"
done
```
Expected: 各シンボルの `T`（テキスト定義）が **1**（posix と darwin の二重定義なし）。

- [ ] **Step 4: 検証結果を plan にチェックして完了**

3 つの検証（build 成功・darwin 採用・二重なし）が揃えば chain モデルは実証完了。失敗時の triage 規則：iOS 非対応 API による build error → その gem に darwin port を追加（同パターン）。port 選択ミス（posix が引かれる）→ loader/conf.ports を再点検。

---

## 完了後

- fork `ios-posix-model` と R2P2-iOS worktree は push せず user に報告。
- 次プラン（別途）：full-REPL gembox（core/stdlib）を posix?=true で iOS に通す移行。`mrbgem.rake` の `if build.posix?` 分岐（shell/editor/mruby/require/yaml/net/ble）の iOS 健全性監査を含む。
- memory `darwin-ports-4gems-plan.md` の旧「#4 設計上ブロック」記述を本モデルに整合更新。
