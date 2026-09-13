# R2P2-darwin Consolidation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** R2P2-iOS と R2P2-macOS を単一 repo `R2P2-darwin` に統合し、examples を platform-first（`examples/{ios,macos,watchos}/<name>`）に再編、rake task を `<platform>:<example>:...` に揃える。

**Architecture:** R2P2-iOS（実体・履歴・watchOS 対応を既に持つ側）を GitHub rename で `R2P2-darwin` にし、R2P2-macOS（自 CLAUDE.md で transitional と宣言済みの薄い harness）を `--allow-unrelated-histories` merge で取り込む。macOS 側タスクは `rakelib/macos.rake` の `namespace :macos` として合流。Rakefile の data-driven 化（重複排除）は本プランのスコープ外（Follow-ups 参照）— 本プランは「動くものを壊さず場所と名前を揃える」まで。

**Tech Stack:** rake / xcodegen / xcodebuild / simctl / gh CLI

**確定済みの決定**（2026-07-03 ユーザー確認済み）:
1. R2P2-iOS を rename（新規 repo は作らない）
2. examples は platform-first
3. R2P2-macOS は統合後 archive + pointer README

**現状スナップショット**（2026-07-03 時点）:
- R2P2-iOS: main, origin より ahead 1 (`2cac21d`)。79 tracked files。examples 6 つ（repl / networking / virtual-peripheral / iphone-torch / stackchan / watch-led-toggle）。`namespace :watch` は `namespace :ios` の内側にある（歴史的経緯）。
- R2P2-macOS: main, origin より ahead 1 (`55ebb5f`)。18 commits。Rakefile + build_config 4 本 + examples/ls.rb のみ。example 実体としての stackchan-pc は存在しない（build config のみ）。
- 両者とも `vendor/picoruby` は untracked（fetch harness）。
- picoruby 側: bash0C7/picoruby の `port-darwin` branch は本日 upstream/master へ rebase + force-push 済み（`752d931c`）。vendor は `rake refresh` で追従が必要。

---

## Phase A: 準備（push とバックアップ）

### Task A1: 未 push commit を両 repo とも push する

**⚠️ USER APPROVAL: push は実行前にユーザー確認**

- [ ] **Step 1: R2P2-iOS の ahead 1 を push**

```bash
cd ~/dev/src/github.com/bash0C7/R2P2-iOS
git log origin/main..main --oneline   # 2cac21d docs: fix CLAUDE.md drift... のみであることを確認
git push origin main
```

- [ ] **Step 2: R2P2-macOS の ahead 1 を push**

```bash
cd ~/dev/src/github.com/bash0C7/R2P2-macOS
git log origin/main..main --oneline   # 55ebb5f feat: stackchan-pc build config... のみであることを確認
git push origin main
```

- [ ] **Step 3: 統合前スナップショットとして両 repo に tag を打って push**

```bash
cd ~/dev/src/github.com/bash0C7/R2P2-iOS   && git tag pre-darwin-consolidation && git push origin pre-darwin-consolidation
cd ~/dev/src/github.com/bash0C7/R2P2-macOS && git tag pre-darwin-consolidation && git push origin pre-darwin-consolidation
```

rollback はこの tag に `git reset --hard` すればよい。

---

## Phase B: R2P2-macOS の取り込み

### Task B1: R2P2-macOS 側で import 用 staging branch を作り、衝突しない配置へ git mv

**Files (R2P2-macOS 内、branch `import-staging`):**
- Move: `Rakefile` → `rakelib/macos.rake`（後続 Task で namespace 化）
- Move: `README.md` → `docs/r2p2-macos-readme.md`（後続 Task で本 README に fold して削除）
- Move: `CLAUDE.md` → `docs/r2p2-macos-claude.md`（同上）
- Move: `examples/ls.rb` → `examples/macos/ls/ls.rb`
- Delete: `.gitignore`（エントリは Task B4 で手動 fold）
- Keep: `build_config/r2p2-picoruby-darwin.rb`, `r2p2-picoruby-darwin-ble.rb`, `r2p2-picoruby-darwin-single.rb`, `r2p2-stackchan-pc.rb`（R2P2-iOS 側とファイル名衝突なし）

- [ ] **Step 1: staging branch で mv**

```bash
cd ~/dev/src/github.com/bash0C7/R2P2-macOS
git checkout -b import-staging
mkdir -p rakelib docs examples/macos/ls
git mv Rakefile rakelib/macos.rake
git mv README.md docs/r2p2-macos-readme.md
git mv CLAUDE.md docs/r2p2-macos-claude.md
git mv examples/ls.rb examples/macos/ls/ls.rb
git rm .gitignore
git commit -m "chore: stage layout for merge into R2P2-darwin"
```

### Task B2: R2P2-iOS へ履歴ごと merge

- [ ] **Step 1: unrelated-histories merge**

```bash
cd ~/dev/src/github.com/bash0C7/R2P2-iOS
git checkout -b consolidate-darwin
git remote add macos ~/dev/src/github.com/bash0C7/R2P2-macOS
git fetch macos
git merge --allow-unrelated-histories macos/import-staging \
  -m "merge: import R2P2-macOS (host harness) into R2P2-darwin"
```

Expected: conflict なし（Task B1 で衝突パスを全て回避済み）。conflict が出たら止めて内容を確認する。

- [ ] **Step 2: merge 結果を確認**

```bash
git ls-files | grep -E 'rakelib/|examples/macos/|build_config/r2p2-picoruby-darwin|r2p2-stackchan-pc'
```

Expected: `rakelib/macos.rake`, `examples/macos/ls/ls.rb`, darwin 系 build config 4 本が見えること。

### Task B3: `rakelib/macos.rake` を namespace :macos に書き換え

旧 R2P2-macOS Rakefile の内容から、main Rakefile と重複する共通部（PICORUBY_REPO/REF/SRC, BUILD_DIR, setup/refresh/clean/clobber）を削り、macOS 固有部だけを `namespace :macos` に残す。**PICORUBY_REPO/REF の default は main Rakefile の値（bash0C7/picoruby @ port-darwin）に一本化**する（旧 macOS default の upstream master は env override で引き続き指定可能）。

**Files:**
- Rewrite: `rakelib/macos.rake`

- [ ] **Step 1: 全面書き換え**

```ruby
# rakelib/macos.rake — macOS (Darwin) host-native build & run.
# Imported from R2P2-macOS. Shares vendor/picoruby, BUILD_DIR, and the
# setup/refresh tasks with the main Rakefile; this file adds only what is
# host-specific: brew openssl flags, host build configs, run, and single.

# Brew openssl@3 prefix on LDFLAGS/CFLAGS so the networking gembox can find
# ssl/crypto. Inert if openssl@3 isn't brew-installed.
def macos_build_env
  env = { "MRUBY_BUILD_DIR" => BUILD_DIR }
  ssl = `brew --prefix openssl@3 2>/dev/null`.strip
  unless ssl.empty?
    env["LDFLAGS"] = [ENV["LDFLAGS"], "-L#{ssl}/lib"].compact.join(" ")
    env["CFLAGS"]  = [ENV["CFLAGS"],  "-I#{ssl}/include"].compact.join(" ")
  end
  cfg = ENV["MRUBY_CONFIG"] || File.join(ROOT, "build_config", "r2p2-picoruby-darwin.rb")
  env["MRUBY_CONFIG"] = File.absolute_path(cfg)
  env
end

namespace :macos do
  desc "Verify macOS host prerequisites (Xcode CLT, brew openssl@3, Swift)"
  task :check do
    ok = true
    if system("xcode-select", "-p", out: File::NULL, err: File::NULL)
      puts "Xcode CLT:  ok"
    else
      warn "Xcode CLT:  missing — run `xcode-select --install`"
      ok = false
    end
    ssl = `brew --prefix openssl@3 2>/dev/null`.strip
    if ssl.empty?
      warn "openssl@3:  missing — run `brew install openssl@3` (networking gem links ssl/crypto)"
      ok = false
    else
      puts "openssl@3:  #{ssl}"
    end
    swift = `swift --version 2>/dev/null`.lines.first&.strip
    if swift.nil? || swift.empty?
      warn "Swift:      missing — install Xcode (needed for the picoruby-ble Darwin port)"
    else
      puts "Swift:      #{swift}"
    end
    abort "missing prerequisites" unless ok
  end

  desc "Host-native build of the fetched picoruby tree into ./build"
  task build: :setup do
    sh macos_build_env, "cd #{PICORUBY_SRC.shellescape} && rake"
  end

  desc "Run the r2p2 shell, or APP=path/to.rb on the picoruby runner"
  task :run do
    r2p2 = File.join(BUILD_DIR, "host", "bin", "r2p2")
    pr   = File.join(BUILD_DIR, "host", "bin", "picoruby")
    if (app = ENV["APP"])
      raise "Not built. Run `rake macos:build` first." unless File.executable?(pr)
      exec({}, pr, app)
    elsif File.executable?(r2p2)
      exec({}, r2p2)
    else
      raise "Not built (or this build has no r2p2 shell — try APP=path/to.rb)."
    end
  end

  desc "Build a single binary embedding APP=path/to/app.rb (NAME defaults to APP basename)"
  task single: :setup do
    app = ENV["APP"] or abort "APP=path/to/app.rb is required"
    abort "APP not found: #{app}" unless File.file?(app)
    name = (ENV["NAME"] || File.basename(app, ".rb")).downcase
    abort "NAME must match /\\A[a-z][a-z0-9_-]*\\z/ (got: #{name.inspect})" unless name =~ /\A[a-z][a-z0-9_-]*\z/

    staging = File.join(ROOT, "tmp", "single")
    gem_dir = File.join(staging, "picoruby-bin-#{name}")
    rm_rf staging
    mkdir_p File.join(gem_dir, "mrblib")
    mkdir_p File.join(gem_dir, "tools", name)

    File.write(File.join(gem_dir, "mrbgem.rake"), <<~MRBGEM)
      MRuby::Gem::Specification.new('picoruby-bin-#{name}') do |spec|
        spec.license = 'MIT'
        spec.author  = ''
        spec.summary = 'PicoRuby single-binary built by rake macos:single'

        spec.add_dependency 'picoruby-mruby'

        bin_name = '#{name}'
        build.bins << bin_name

        main_src = "\#{spec.dir}/tools/\#{bin_name}/\#{bin_name}.c"
        bin_obj  = objfile(main_src.pathmap("\#{build_dir}/tools/\#{bin_name}/%n"))

        file bin_obj => [main_src] do |t|
          build.cc.run t.name, main_src
        end

        file exefile("\#{build.build_dir}/bin/\#{bin_name}") => [bin_obj, build.libmruby_static] do |f|
          build.linker.run f.name, f.prerequisites
        end
      end
    MRBGEM

    cp app, File.join(gem_dir, "mrblib", "app.rb")

    File.write(File.join(gem_dir, "tools", name, "#{name}.c"), <<~C_MAIN)
      #include <stdio.h>
      #include <stdint.h>

      #if !defined(PICORB_PLATFORM_POSIX)
      #define PICORB_PLATFORM_POSIX 1
      #endif

      #include "picoruby.h"

      #ifndef HEAP_SIZE
      #define HEAP_SIZE (1024 * 2000)
      #endif

      static uint8_t vm_heap[HEAP_SIZE] __attribute__((aligned(16)));

      mrb_state *global_mrb = NULL;

      int main(int argc, char **argv) {
        (void)argc;
        mrb_state *vm = NULL;
        picorb_vm_init();
        mrb_close(vm);
        return 0;
      }
    C_MAIN

    single_cfg = File.join(ROOT, "build_config", "r2p2-picoruby-darwin-single.rb")
    env = macos_build_env.merge(
      "MRUBY_CONFIG"         => File.absolute_path(single_cfg),
      "R2P2_SINGLE_GEM_PATH" => gem_dir,
    )
    sh env, "cd #{PICORUBY_SRC.shellescape} && rake"

    puts ""
    puts "Single binary built: #{File.join(BUILD_DIR, "host", "bin", name)}"
  end
end
```

注意点（旧ファイルからの差分）:
- `R2P2_MACOS_ROOT` → main Rakefile の `ROOT` を利用
- `PICORUBY_REPO/REF/SRC/BUILD_DIR` の再定義を削除（main Rakefile のものを使う）
- `setup` / `refresh` / `clean` / `clobber` / `default` を削除（main Rakefile 側に既存）
- `build_env` → `macos_build_env` に rename（main Rakefile の `mruby_env` と衝突しないよう明示）
- `task build: :setup` の `:setup` は main Rakefile の top-level setup を指す

- [ ] **Step 2: 動作確認（macOS host build）**

```bash
cd ~/dev/src/github.com/bash0C7/R2P2-iOS
rake refresh          # port-darwin force-push 済みのため必須
rake macos:check
rake macos:build
rake macos:single APP=examples/macos/ls/ls.rb
./build/host/bin/ls   # ls.rb 単体バイナリが動くこと
```

Expected: build 成功、`ls` バイナリがカレントのファイル一覧を出力。

- [ ] **Step 3: Commit**

```bash
git add rakelib/macos.rake
git commit -m "feat(macos): fold R2P2-macOS harness into namespace :macos"
```

### Task B4: .gitignore の fold

**Files:**
- Modify: `.gitignore`

- [ ] **Step 1: R2P2-macOS 由来のエントリを追記**

既存の R2P2-iOS `.gitignore` 末尾に追加:

```gitignore
# macos:single staging
/tmp/
# Claude Code local-only settings (permission grants etc.)
.claude/settings.local.json
```

（`/vendor/` `/build/` `docs/superpowers/` `/HANDOFF.md` は既存エントリと重複するため追加しない）

- [ ] **Step 2: Commit**

```bash
git add .gitignore
git commit -m "chore: fold R2P2-macOS gitignore entries"
```

---

## Phase C: examples の platform-first 再編と task 呼び分け

### Task C1: ディレクトリ移動

- [ ] **Step 1: git mv**

```bash
cd ~/dev/src/github.com/bash0C7/R2P2-iOS
mkdir -p examples/ios examples/watchos
git mv examples/repl               examples/ios/repl
git mv examples/networking         examples/ios/networking
git mv examples/virtual-peripheral examples/ios/virtual-peripheral
git mv examples/iphone-torch       examples/ios/iphone-torch
git mv examples/stackchan          examples/ios/stackchan
git mv examples/watch-led-toggle   examples/watchos/led-toggle
```

（`examples/macos/ls/` は Phase B で配置済み）

- [ ] **Step 2: .gitignore の階層を 1 段深くする**

```gitignore
# 変更前
/examples/*/Vendor/
/examples/*/*.xcodeproj
# 変更後
/examples/*/*/Vendor/
/examples/*/*/*.xcodeproj
```

- [ ] **Step 3: Commit（Rakefile 修正前なので build は壊れている状態。次 Task とまとめず、mv だけの commit で履歴を追いやすくする）**

```bash
git add -A examples .gitignore
git commit -m "refactor(examples): platform-first layout — examples/{ios,macos,watchos}/<name>"
```

### Task C2: Rakefile のパス定数と namespace を新レイアウトに追従

**Files:**
- Modify: `Rakefile`

- [ ] **Step 1: 汎用 EXAMPLE パイプラインのパスを ios/ 配下に**

```ruby
# 変更前 (Rakefile:10)
APP_DIR       = File.join(ROOT, "examples", EXAMPLE)
# 変更後
APP_DIR       = File.join(ROOT, "examples", "ios", EXAMPLE)
```

- [ ] **Step 2: 各 example namespace の DIR 定数を置換**

Rakefile 内の以下の文字列を全て置換（各 namespace 冒頭の定数定義）:

| 変更前 | 変更後 |
|---|---|
| `File.join(ROOT, "examples", "stackchan")` | `File.join(ROOT, "examples", "ios", "stackchan")` |
| `File.join(ROOT, "examples", "virtual-peripheral")` | `File.join(ROOT, "examples", "ios", "virtual-peripheral")` |
| `File.join(ROOT, "examples", "iphone-torch")` | `File.join(ROOT, "examples", "ios", "iphone-torch")` |
| `File.join(ROOT, "examples", "networking")` | `File.join(ROOT, "examples", "ios", "networking")` |
| `File.join(ROOT, "examples", "watch-led-toggle")` | `File.join(ROOT, "examples", "watchos", "led-toggle")` |

- [ ] **Step 3: watch namespace を ios: の外へ出し watchos:led に rename**

`namespace :ios do` 内の `namespace :watch do ... end`（Rakefile:471〜）ブロック全体を `namespace :ios` の閉じ `end` の後ろへ移動し、宣言を変更:

```ruby
# 変更前（ios: の内側）
  namespace :watch do
# 変更後（top-level）
namespace :watchos do
  namespace :led do
```

ブロック内の task 参照文字列も置換:

```ruby
# 変更前
task all: [:lib, "ios:watch:gen", :build, :run]
# 変更後
task all: [:lib, "watchos:led:gen", :build, :run]
```

（`"ios:watch:` を grep して全ヒットを `"watchos:led:` に置換。インデントを 1 段浅くする）

- [ ] **Step 4: rake -T が全 namespace を列挙できることを確認**

```bash
rake -T | grep -E '^rake (ios|macos|watchos):' | head -40
```

Expected: `ios:*`（repl 汎用 + stackchan/vperiph/torch/net）, `macos:{check,build,run,single}`, `watchos:led:*` が並び、`ios:watch:*` が消えていること。

- [ ] **Step 5: Simulator ビルドで新パスの疎通確認（実機不要の範囲）**

```bash
rake ios:lib ios:gen ios:build          # repl (default EXAMPLE) → examples/ios/repl
rake watchos:led:lib watchos:led:gen watchos:led:build
```

Expected: 両方 BUILD SUCCEEDED。`examples/ios/repl/Vendor/` と `examples/watchos/led-toggle/Vendor/` が生成される。

- [ ] **Step 6: Commit**

```bash
git add Rakefile
git commit -m "refactor(rake): follow platform-first layout; watch → top-level watchos:led"
```

### Task C3: 実機パイプラインの手動確認（ユーザー協力・任意タイミング）

自動検証できない（署名済み実機・ペアリング済み Watch・2 台目 BLE 機材が必要な）ため、統合後の任意時点でユーザー立ち会いのもと実施。plan の完了条件には含めない。

- [ ] `rake ios:device:all`（iPhone 実機）
- [ ] `rake ios:stackchan:device:all`（BLE peripheral 側機材も必要）
- [ ] `rake watchos:led:device:all`（Apple Watch）

---

## Phase D: ドキュメント統合

### Task D1: README.md を R2P2-darwin として書き直す

**Files:**
- Modify: `README.md`
- Delete: `docs/r2p2-macos-readme.md`（fold 後）

- [ ] **Step 1: 構成を platform-first に組み替える**

現 README（R2P2-iOS, 303 行）をベースに:
- タイトル・冒頭を `# R2P2-darwin` /「PicoRuby を Apple プラットフォーム（macOS / iOS / watchOS）で build・実行する harness」に変更
- `## Examples` を `### iOS` `### macOS` `### watchOS` の 3 小節に分け、既存 6 example の記述は該当小節へ移動（パスとタスク名を新形式に更新: 例 `rake ios:stackchan:all`、`examples/ios/stackchan/`）
- `docs/r2p2-macos-readme.md` から「Choosing what to build」「Standard build」「Single binary build」「ls.rb demo」を `### macOS` 小節へ fold（タスク名を `rake macos:build` 等へ更新）
- Setup 節: iOS/watchOS には full Xcode.app + xcodegen、macOS host build には CLT + brew openssl@3 で足りる旨を統合表記
- 旧 R2P2-macOS / 旧名 R2P2-iOS への言及は削除（時系列参照を書かない — 現在形で書く）

- [ ] **Step 2: fold 済みの staging doc を削除して commit**

```bash
git rm docs/r2p2-macos-readme.md
git add README.md
git commit -m "docs: rewrite README as R2P2-darwin (platform-first examples)"
```

### Task D2: CLAUDE.md を統合

**Files:**
- Modify: `CLAUDE.md`
- Delete: `docs/r2p2-macos-claude.md`（fold 後）

- [ ] **Step 1: 統合**

現 CLAUDE.md（52 行）に、旧 R2P2-macOS CLAUDE.md から今も真である事実だけを fold:
- repo の責務: 「Apple 全 platform（macOS host native / iOS / watchOS cross）の build harness」
- build config の命名規約（`r2p2-<runtime>-<target>.rb`）と darwin host base / ble opt-in の説明
- 「picoruby/picoruby が Darwin host config を取り込んだら macOS host 部分は役目を終える」という transitional 性は、macos: namespace の節として残す
- 旧 repo 名への言及・「statement は 2026-06-20 時点」等の時系列参照は書かない

- [ ] **Step 2: Commit**

```bash
git rm docs/r2p2-macos-claude.md
git add CLAUDE.md
git commit -m "docs(CLAUDE.md): cover macos namespace and darwin build config conventions"
```

---

## Phase E: 公開（rename / push / archive）

**⚠️ USER APPROVAL: この Phase の全操作（push, repo rename, archive）は 1-way door。実行前にまとめてユーザー確認**

### Task E1: consolidate branch を main に merge して push

- [ ] **Step 1: main へ**

```bash
cd ~/dev/src/github.com/bash0C7/R2P2-iOS
git checkout main
git merge --no-ff consolidate-darwin -m "merge: R2P2-darwin consolidation (import R2P2-macOS, platform-first examples)"
git push origin main
```

### Task E2: GitHub repo rename と local 追従

- [ ] **Step 1: rename（redirect は GitHub が自動維持）**

```bash
gh repo rename R2P2-darwin -R bash0C7/R2P2-iOS --yes
```

- [ ] **Step 2: local remote と directory を追従**

```bash
cd ~/dev/src/github.com/bash0C7/R2P2-iOS
git remote set-url origin https://github.com/bash0C7/R2P2-darwin.git
cd ~/dev/src/github.com/bash0C7
mv R2P2-iOS R2P2-darwin
```

- [ ] **Step 3: 疎通確認**

```bash
cd ~/dev/src/github.com/bash0C7/R2P2-darwin && git fetch origin && git status -sb
```

Expected: `## main...origin/main`（乖離なし）。

### Task E3: R2P2-macOS を pointer README 化して archive

- [ ] **Step 1: pointer README に差し替え**

```bash
cd ~/dev/src/github.com/bash0C7/R2P2-macOS
git checkout main
```

`README.md` を以下の内容で全置換（他ファイルは履歴保存のため残す）:

```markdown
# R2P2-macOS → moved to R2P2-darwin

This harness now lives in [R2P2-darwin](https://github.com/bash0C7/R2P2-darwin)
together with the iOS / watchOS build harness. The macOS host tasks are under
the `macos:` rake namespace there (`rake macos:build`, `rake macos:run`,
`rake macos:single`).

The full commit history of this repository was merged into R2P2-darwin.
```

- [ ] **Step 2: commit / push / archive**

```bash
git add README.md
git commit -m "docs: point to R2P2-darwin (repository merged and archived)"
git push origin main
gh repo archive bash0C7/R2P2-macOS --yes
```

- [ ] **Step 3: R2P2-darwin 側の一時 remote を掃除**

```bash
cd ~/dev/src/github.com/bash0C7/R2P2-darwin
git remote remove macos
```

---

## Follow-ups（本プランのスコープ外・別プランで）

1. **Rakefile の data-driven 化**: 各 example namespace は lib→gen→build→run の同型パイプラインの複製（648 行の大半）。examples テーブル（name / platform / config / bundle id / scheme）から namespace をループ生成する refactor。C 系 Task 完了で新レイアウトが安定してから着手。
2. **build_config の合成 helper**: 17 本の config は SDK 軸（iphonesimulator / iphoneos / watchsimulator / watchos）× gem set 軸の直積。`apple_cross_build(sdk:, arch:, min:)` helper で薄い宣言に畳む。CrossBuild name（= build dir 名）は変えない。
3. **stackchan-pc の example 化**: 現状 build config のみ（`r2p2-stackchan-pc.rb`）。app 実体が固まったら `examples/macos/stackchan-pc/` を作る。picoruby-port-darwin worktree に残る untracked `build-stackchan-pc/`（149MB, build 成果物）はこの流れで整理。
4. **local directory 名の整合**: `~/dev/src/github.com/bash0C7/picoruby-port-darwin`（picoruby の worktree）はそのまま。R2P2-ESP32 は独立 repo のまま（ESP-IDF harness として恒久必要 — 旧 R2P2-macOS CLAUDE.md の対比記述の通り）。
