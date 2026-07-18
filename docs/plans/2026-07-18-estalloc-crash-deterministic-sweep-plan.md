# 決定論的スイープによる est_free crash 真因特定 — 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 各タスク冒頭の **Model** に従い subagent のモデルを指定すること。

**Goal:** `examples/ios/repl` 起動〜teardown 時の `est_free` `EXC_BAD_ACCESS` の真因を〈commit × build-param〉空間の crash on/off 境界として特定し、実 example が本来の teardown 経路のまま Simulator で正しく動く状態にする。過程で確立する決定論ビルド + 検証を R2P2-darwin の公式ターゲットとして版管理する。

**Architecture:** 既存の `Rakefile` / `build_config` を更新して (1) content-hash による決定論ビルド検証、(2) example-works + crash 観測、を公式 rake ターゲット化する。env epoch を凍結した 1 台の Simulator でこれらを回し、候補 commit を scripted-build で bisect → 境界 commit で build-param を単一変数対照して真因を絞る。

**Tech Stack:** Ruby (rake), picoruby cross-build (`MRUBY_BUILD_DIR=./build`), xcodegen, xcodebuild, `xcrun simctl`, git worktree, sha256。

**Model 配分（横断）:** 決定論的コマンド実行（ビルド・git・observe run・hash）=**haiku** / コード変更（Rakefile・build_config・bridge）=**sonnet** / 探索・計画・真因推論・レビュー=**opus**。各委譲は目的・背景を添え、出力は最小限に絞る。

**記録先:** すべての観測・pin・findings は `docs/plans/2026-07-18-estalloc-sweep-log.md`（以下「sweep log」）に追記する。sweep log は本計画の実行で新規作成する単一の source of truth。

---

## File Structure

- Create: `docs/plans/2026-07-18-estalloc-sweep-log.md` — 環境 pin・findings・スイープ結果表。
- Modify: `Rakefile` — 公式ターゲット `determinism:ios:repl` と `ios:repl:observe` を追加。
- Modify (真因が build-param 起因の場合): `build_config/r2p2-picoruby-ios-repl-sim.rb` +
  `examples/ios/repl/project.yml` — defines の single source 化。加えて
  `bridge/picoruby_bridge.c` — ワークアラウンド除去（`mrb_close` 復活）。
- Modify (真因が estalloc 起因の場合): upstream bug report 草稿（`docs/plans/` 配下）。
- 一時成果: `build/observe/*.txt`（observe の捕捉ログ・golden）。`.gitignore` の `build/` 配下で追跡外。

---

## Phase 1 — Root cause investigation（foundation + facts。飛ばさない）

### Task 1: 決定論環境の pin と env epoch 凍結

**Model:** haiku（コマンド実行）→ opus（記録の整形）

**Files:**
- Create: `docs/plans/2026-07-18-estalloc-sweep-log.md`

- [ ] **Step 1: 現在の版を採取**

Run:
```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
echo "repo HEAD: $(git rev-parse HEAD)"
echo "vendor ref: $(git -C vendor/picoruby rev-parse HEAD 2>/dev/null || echo MISSING)"
echo "estalloc ref: $(git -C vendor/picoruby/mrbgems/picoruby-mruby/lib/mruby/mrbgems/mruby-estalloc rev-parse HEAD 2>/dev/null || echo UNKNOWN_PATH)"
cat .ruby-version
ruby -v
```
Expected: HEAD/vendor ref のハッシュが出る。estalloc のパスが UNKNOWN なら Step で正しいサブモジュールパスを `git -C vendor/picoruby submodule status` で特定して記録。`ruby -v` が 4.0.5 でなければ `RBENV_VERSION=4.0.5` を export（vendor の numbered-parameter 構文対策）。

- [ ] **Step 2: env epoch を凍結する Simulator を 1 台決める**

Run:
```bash
xcrun simctl list devices available | grep -i "iPhone" | head -20
```
1 台選び UDID を採る（booted があればそれを優先）。以後この 1 台のみを使い、**再作成・削除・factory reset をしない**。

- [ ] **Step 3: sweep log に pin を記録**

`docs/plans/2026-07-18-estalloc-sweep-log.md` を新規作成し、以下を書く（実値で埋める）:
```markdown
# estalloc sweep log

## Pins (Task 1)
- repo HEAD: <hash>
- vendor/picoruby ref: <hash> (PICORUBY_REF=port-darwin)
- estalloc submodule path/ref: <path> <hash>
- ruby: 4.0.5 (RBENV_VERSION=4.0.5 を全 build/observe で export)
- frozen Simulator: <name> UDID=<udid> — 再作成/削除/reset 禁止
```

- [ ] **Step 4: commit**

```bash
git add docs/plans/2026-07-18-estalloc-sweep-log.md
git commit -m "chore(debug): pin env + freeze Simulator epoch for estalloc sweep"
```

---

### Task 2: 再現トリガと example の正常出力（golden）を app sources から特定

**Model:** opus（コード読解・因果推論）

**Files:**
- Read: `examples/ios/repl/Sources/`（全 Swift + bridging header）
- Read: `bridge/picoruby_bridge.c`（`repl_eval` / `vm_open` / `vm_close` の呼ばれ方）
- Read: repl example の boot Ruby（`examples/ios/repl/Sources` 配下の `.rb` または埋め込み文字列）
- Modify: sweep log（findings 追記）

- [ ] **Step 1: 起動〜teardown の呼び出しグラフを確定**

`examples/ios/repl/Sources/` の Swift と `bridge/picoruby_bridge.c` を読み、次の問いに答える:
1. app 起動時に `vm_open` の boot 実行だけが走るのか、`repl_eval`（signature が指す crash 経路）が自動で走るのか、それとも user 入力の eval が要るのか。
2. crash signature `mrb_close ← repl_eval` の `mrb_close` は現状コメントアウト（`bridge/picoruby_bridge.c:113`）。これを復活させた時に、**起動〜最初の自動処理だけで** teardown 経路に到達するか、UI 入力が要るか。
3. example が正常動作した時に stdout/os_log に出る**決定論的な文字列**（boot バナー等）は何か。

- [ ] **Step 2: sweep log に findings を記録**

sweep log に追記:
```markdown
## Repro trigger + golden (Task 2)
- 起動で走る経路: <vm_open boot のみ / repl_eval 自動 / UI 入力必要>
- mrb_close teardown 到達条件: <起動だけ / UI 入力 X が必要>
- 正常時の決定論出力(golden 候補): "<文字列>"
- observe を UI 入力なしで crash 到達させる手段: <boot Ruby にトリガを埋める / simctl で eval を送る / 起動だけで足りる>
```
UI 入力が必須で scripted に送れない場合の代替（boot Ruby に最小の eval+teardown を仕込んだ observe 専用 boot を、build_config 経由で決定論的に注入する）もここで方針決定し記録する。**ad-hoc な手作業入力は禁止**。

- [ ] **Step 3: commit**

```bash
git add docs/plans/2026-07-18-estalloc-sweep-log.md
git commit -m "docs(debug): record repl repro trigger and golden output"
```

---

### Task 3: 履歴地形マップ（候補 commit 導出。scripted、行き当たりばったりにしない）

**Model:** opus（分析）＋ haiku（git 実行）

**Files:**
- Read (scripted git): `bridge/picoruby_bridge.c`, `build_config/r2p2-picoruby-ios-repl-sim.rb`, `examples/ios/repl/project.yml`, `Rakefile`（`PICORUBY_REF` 既定）
- Modify: sweep log

- [ ] **Step 1: 変更点を触った commit を列挙**

Run:
```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
echo "== teardown (mrb_close) =="
git log --oneline -S 'mrb_close' -- bridge/picoruby_bridge.c
echo "== ios repl build_config defines =="
git log --oneline -p -- build_config/r2p2-picoruby-ios-repl-sim.rb | grep -E '^(commit|\+.*defines|\-.*defines)' | head -80
echo "== project.yml defines =="
git log --oneline -p -- examples/ios/repl/project.yml | grep -E '^(commit|\+.*MRB_|\-.*MRB_|\+.*PICORB|\-.*PICORB)' | head -80
echo "== PICORUBY_REF default =="
git log --oneline -S 'PICORUBY_REF' -- Rakefile
```
Expected: 各観点で commit ハッシュ列が出る。

- [ ] **Step 2: define 不一致の現状を事実確認**

現行の libmruby 側と app 側の define 差（spec §2.5 の 4 つ）が picoruby default で補われていないかを確認:
```bash
grep -nE 'MRB_USE_TASK_SCHEDULER|MRB_USE_VM_SWITCH_DISPATCH|MRB_CONSTRAINED_BASELINE_PROFILE|MRB_HEAP_PAGE_SIZE' \
  build_config/r2p2-picoruby-ios-repl-sim.rb examples/ios/repl/project.yml
grep -rnE 'MRB_USE_TASK_SCHEDULER|MRB_HEAP_PAGE_SIZE' vendor/picoruby/build_config/ 2>/dev/null | head
```
Expected: 4 define が app 側(project.yml)のみに在り、build_config 側と vendor default に無ければ「境界をまたぐ ABI 不一致」の候補として確定。picoruby default が設定していれば当該 define を軸から外す。

- [ ] **Step 3: sweep log に候補 commit 表を記録**

sweep log に、時系列順で「候補 commit / 日付 / 触った観点 / crash 仮説への関与」を表で追記。bisect 対象範囲（good 端＝crash しない古い commit 候補、bad 端＝crash する commit 候補）を明記。

- [ ] **Step 4: commit**

```bash
git add docs/plans/2026-07-18-estalloc-sweep-log.md
git commit -m "docs(debug): history-terrain map of candidate commits for the crash"
```

---

### Task 4: 公式ターゲット `determinism:ios:repl`（content-hash 決定論検証）を Rakefile に追加

**Model:** sonnet（コード変更）

**Files:**
- Modify: `Rakefile`（末尾付近、`namespace :host` の後に `namespace :determinism` を追加）

- [ ] **Step 1: 決定論検証タスクを追加**

`Rakefile` に以下を追加する:
```ruby
require "digest"

# Deterministic-build verification: the same (commit, build_config, vendor tree)
# must produce a byte-identical libmruby.a. Guards against the "100KB drift"
# where an unnoticed input change silently altered the archive.
namespace :determinism do
  desc "Verify ios-repl libmruby.a is byte-identical across two clean builds"
  task :"ios:repl" do
    lib = File.join(BUILD_DIR, "ios-repl-sim", "lib", "libmruby.a")
    hashes = (1..2).map do |i|
      rm_rf File.join(BUILD_DIR, "ios-repl-sim")
      Rake::Task["ios:repl:lib"].reenable
      Rake::Task["setup"].reenable
      Rake::Task["ios:repl:lib"].invoke
      h = Digest::SHA256.file(lib).hexdigest
      puts "build #{i}: #{h}"
      h
    end
    if hashes.uniq.size == 1
      puts "DETERMINISTIC ok: #{hashes.first}"
    else
      abort "NON-DETERMINISTIC: #{hashes.inspect} — investigate embedded timestamps/paths/ar ordering"
    end
  end
end
```

- [ ] **Step 2: 実行して決定論を確認**

Run:
```bash
RBENV_VERSION=4.0.5 rake determinism:ios:repl 2>&1 | tail -5
```
Expected: `DETERMINISTIC ok: <sha256>`。
NON-DETERMINISTIC の場合は sweep log に記録し、非決定源を特定する子タスクを起こす（ar のタイムスタンプ → `ar` に `D` フラグ相当 / `zero_ar_date`、埋め込み絶対パス → `-fdebug-prefix-map` 等）。**この場合は決定論確立が最優先で、以降の bisect の前提が崩れるため先に潰す。**

- [ ] **Step 3: sweep log に baseline hash を記録して commit**

```bash
git add Rakefile docs/plans/2026-07-18-estalloc-sweep-log.md
git commit -m "feat(rake): official determinism:ios:repl content-hash verify target"
```

---

### Task 5: 公式ターゲット `ios:repl:observe`（example-works + crash 観測）を Rakefile に追加

**Model:** sonnet（コード変更）

**Files:**
- Modify: `Rakefile`（`define_ios_example` 内、`ios:<name>:run` の隣に `observe` を追加）

- [ ] **Step 1: observe タスクを追加**

`define_ios_example` の `namespace name do` ブロック内（`task all:` の前）に追加する。env epoch 凍結のため boot のみで install/launch し、crash と golden を判定する:
```ruby
      desc "Observe #{label}: launch on frozen Simulator (env SIM_UDID), classify OK/CRASH over N runs (env OBSERVE_N=5)"
      task :observe do
        app  = built_app(derived, "*-iphonesimulator", scheme, "ios:#{name}:build")
        udid = ENV["SIM_UDID"] or abort "set SIM_UDID to the frozen-epoch Simulator (sweep log Task 1)"
        n    = (ENV["OBSERVE_N"] || "5").to_i
        outdir = File.join(ROOT, "build", "observe"); mkdir_p outdir
        sh "xcrun simctl boot #{udid} 2>/dev/null; true"
        sh "xcrun simctl install #{udid} #{app.shellescape}"
        results = (1..n).map do |i|
          log = File.join(outdir, "#{name}_run#{i}.txt")
          # --console-pty streams the app's stdio until it exits; capture it.
          sh "xcrun simctl launch --terminate-running-process --console-pty #{udid} #{bundle} > #{log.shellescape} 2>&1; true"
          body = File.read(log)
          if body =~ /EXC_BAD_ACCESS|remove_free_block|est_free/
            :crash
          else
            :ok
          end
        end
        tally = results.tally
        puts "observe #{name}: #{tally.inspect} over #{n} runs (logs: #{outdir})"
        golden = File.join(outdir, "#{name}_golden.txt")
        if File.exist?(golden)
          last = File.join(outdir, "#{name}_run#{n}.txt")
          puts(FileUtils.identical?(golden, last) ? "GOLDEN match" : "GOLDEN mismatch (compare #{last} vs #{golden})")
        end
        abort "NON-DETERMINISTIC observe: #{tally.inspect}" if tally.size > 1
      end
```

- [ ] **Step 2: 現 HEAD（WA 有効）で observe が OK deterministic になることを確認**

Run:
```bash
SIM_UDID=<udid> RBENV_VERSION=4.0.5 rake ios:repl:lib ios:repl:gen ios:repl:build ios:repl:observe 2>&1 | tail -5
```
Expected: `observe repl: {ok=>5} over 5 runs`（WA が効いていれば crash しない）。
crash 検出が Task 2 の「UI 入力必須」に阻まれ起動だけで teardown へ到達しない場合は、Task 2 で決めた observe 専用トリガ（boot Ruby へ最小 eval+teardown を決定論注入する build_config オプション）を実装してから再実行する。

- [ ] **Step 3: golden を確定して commit**

正常出力を確認できたら `build/observe/repl_run5.txt` を `build/observe/repl_golden.txt` に採用（sweep log に golden の中身も転記）。
```bash
git add Rakefile docs/plans/2026-07-18-estalloc-sweep-log.md
git commit -m "feat(rake): official ios:repl:observe example-works + crash classifier"
```

---

## Phase 2 — 仮説検証（スイープ。承認済みアプローチ A）

### Task 6: crash baseline の確立（WA 無しで決定論的に crash させられるか）

**Model:** haiku（worktree/build/observe）＋ opus（判定）

**Files:**
- Worktree 経由で `bridge/picoruby_bridge.c` の WA を無効化（`mrb_close` を復活）した状態をビルド。
- Modify: sweep log

- [ ] **Step 1: 隔離 worktree を用意（using-git-worktrees）**

REQUIRED SUB-SKILL: `superpowers:using-git-worktrees` で crash baseline 用の隔離ワークスペースを作る。

- [ ] **Step 2: WA を revert して mrb_close を復活**

worktree で `bridge/picoruby_bridge.c:113` の `/* mrb_close(mrb); */` と `:213` の `/* mrb_close(h->mrb); */` を有効行に戻す（Task 9 の一貫化前の、素の元経路を再現）。

- [ ] **Step 3: 公式ターゲットでビルド + observe**

Run:
```bash
SIM_UDID=<udid> RBENV_VERSION=4.0.5 rake ios:repl:lib ios:repl:gen ios:repl:build ios:repl:observe 2>&1 | tail -8
```
Expected（仮説通りなら）: `observe repl: {crash=>5}` かつ signature 一致。
- **決定論的に crash する** → baseline 確立。libmruby.a と app の sha256 を sweep log に content-hash 付きで凍結（前回消した ground truth を今回は残す）。
- **crash と ok が混在する** → まだ統制外の入力がある。observe の非決定を abort が捕えるので、原因（epoch 以外の入力）を特定して潰すまで先に進まない。
- **決定論的に ok（crash しない）** → 現行 build-param では素の経路でも crash しない。これ自体が重要 finding。Task 7 の commit 軸で crash する commit を探すか、Task 8 の param 軸へ直行する判断を sweep log に記録。

- [ ] **Step 4: sweep log に baseline を記録して commit（worktree 側）**

```bash
git add bridge/picoruby_bridge.c docs/plans/2026-07-18-estalloc-sweep-log.md
git commit -m "debug: crash baseline (mrb_close restored) build+observe result"
```

---

### Task 7: commit 軸を scripted-build で bisect

**Model:** opus（bisect の good/bad 判定と次手選択）＋ haiku（各 commit の build+observe）

**Files:**
- Modify: sweep log（各 commit の結果表）

- [ ] **Step 1: bisect レンジを確定**

Task 3 の候補表から good 端（crash しない古い commit）と bad 端（crash する commit）を置く。build-param は canonical（現 build_config）に固定し、変える変数を commit だけにする。各 commit で **mrb_close は復活済み**（Task 6 の baseline 経路）に揃える — teardown 経路を常に有効化した状態で commit 差だけを見る。

- [ ] **Step 2: 各候補 commit を同一手順でビルド + observe**

各 commit につき（worktree を当該 commit に checkout し、Task 6 と同じ mrb_close 復活を適用してから）:
```bash
SIM_UDID=<udid> RBENV_VERSION=4.0.5 rake determinism:ios:repl 2>&1 | tail -2
SIM_UDID=<udid> RBENV_VERSION=4.0.5 rake ios:repl:lib ios:repl:gen ios:repl:build ios:repl:observe 2>&1 | tail -5
```
各 commit の (hash, determinism ok?, example-works?, crash/ok) を sweep log の表に記録。**example が動かない commit はゲート除外**として明記し、判定に混ぜない。

- [ ] **Step 3: 境界 commit を特定**

crash 再現が on/off に切り替わる commit を絞る。その commit の diff（触った build-param / 経路）を sweep log に記録。これが真因への最短手がかり。

- [ ] **Step 4: commit（記録）**

```bash
git add docs/plans/2026-07-18-estalloc-sweep-log.md
git commit -m "debug: commit-axis bisect result, crash boundary identified"
```

---

### Task 8: 境界 commit で build-param 軸の単一変数対照

**Model:** sonnet（build_config 変更）＋ haiku（build+observe）＋ opus（判定）

**Files:**
- Modify: `build_config/r2p2-picoruby-ios-repl-sim.rb`（対照のため 1 define ずつ変える。worktree 内）
- Modify: sweep log

- [ ] **Step 1: define 一貫性を単一変数として対照**

境界 commit（crash 側）で、libmruby 側 build_config に app 側のみの define を **1 つずつ**足して observe:
```bash
# 例: MRB_HEAP_PAGE_SIZE=128 を libmruby 側にも一致させる 1 変数だけ変更 → 再ビルド → observe
SIM_UDID=<udid> RBENV_VERSION=4.0.5 rake ios:repl:lib ios:repl:gen ios:repl:build ios:repl:observe 2>&1 | tail -5
```
`MRB_USE_TASK_SCHEDULER=1` / `MRB_USE_VM_SWITCH_DISPATCH=1` / `MRB_CONSTRAINED_BASELINE_PROFILE=1` / `MRB_HEAP_PAGE_SIZE=128` を各々単独で試し、どれが crash を on/off させるかを表に記録。

- [ ] **Step 2: 真因の帰属を確定**

- ある単一 define の不一致が crash を決定論的に flip する → **build-param 起因（ABI 不一致）。R2P2-darwin 側の責。** Task 9-A へ。
- どの define も flip せず、build-param を app と完全一致させても crash が残る → **estalloc/mruby 内部起因**。Task 9-B へ。§5 の victim/culprit 決着観測（size フィールド + footer の 2 番地 watchpoint）を、この決定論 baseline 上で 1 回だけ実施して加害者を確定。

- [ ] **Step 3: sweep log に真因帰属を記録して commit**

```bash
git add build_config/r2p2-picoruby-ios-repl-sim.rb docs/plans/2026-07-18-estalloc-sweep-log.md
git commit -m "debug: param-axis controlled experiment, root cause attributed"
```

---

## Phase 3/4 — 修正と完了基準ゲート

### Task 9-A: build-param 起因の場合 — defines を single source 化し WA 除去

**Model:** sonnet（コード変更）

**Files:**
- Modify: `build_config/r2p2-picoruby-ios-repl-sim.rb`, `examples/ios/repl/project.yml`
- Modify: `bridge/picoruby_bridge.c`（WA 除去 = `mrb_close` 復活を本流に取り込み）

- [ ] **Step 1: defines を単一ソース化**

libmruby 側 build_config と app 側 project.yml の `GCC_PREPROCESSOR_DEFINITIONS` が
ドリフトしない構造にする。定義集合を 1 箇所（例: `build_config` 内の共有定数、または
project.yml が参照する生成ファイル）に置き、両者が同じ集合を使うようにする。Task 8 で
crash を消した define を含め、libmruby と app の ABI を一致させる。

- [ ] **Step 2: WA を除去（mrb_close を本流で復活）**

`bridge/picoruby_bridge.c:113` と `:213` のコメントアウトを解き、`mrb_close` を通常経路に戻す。error パスの `mrb_close`（`:144/157/166`）はそのまま。

- [ ] **Step 3: 決定論ビルド + observe で crash 消失を確認**

Run:
```bash
SIM_UDID=<udid> RBENV_VERSION=4.0.5 rake determinism:ios:repl 2>&1 | tail -2
SIM_UDID=<udid> RBENV_VERSION=4.0.5 rake ios:repl:lib ios:repl:gen ios:repl:build ios:repl:observe 2>&1 | tail -5
```
Expected: `DETERMINISTIC ok` かつ `observe repl: {ok=>5}` かつ GOLDEN match（**mrb_close 復活済み = 本来の teardown 経路**で crash しない）。

- [ ] **Step 4: commit**

```bash
git add build_config/ examples/ios/repl/project.yml bridge/picoruby_bridge.c
git commit -m "fix(build): unify libmruby/app defines (single source); drop mrb_close workaround"
```

---

### Task 9-B: estalloc/mruby 起因の場合 — 決定論再現付き bug report 草稿

**Model:** opus（起草・技術判断）

**Files:**
- Create: `docs/plans/2026-07-18-estalloc-or-mruby-bug-report.md`

- [ ] **Step 1: 決定論再現を添えた草稿を書く**

Task 6 の凍結 baseline（content-hash 付き libmruby.a + app）と observe 手順、Task 8 の
victim/culprit 決着観測を根拠に、宛先（estalloc か mruby か §5 の決着次第）へ最小再現付きの
草稿を書く。「corruption 無し」等の未決断定を書かない（証拠が支持する範囲のみ）。

- [ ] **Step 2: WA の扱いを決める**

真因が upstream 側なら、WA（`mrb_close` 無効化）は暫定回避として本流に残す判断が妥当。
その論拠（`free(heap)` が pool を回収するので teardown の est_free を回避）を bridge の
コメントに残し、bug 修正後に除去する旨を sweep log に記録。

- [ ] **Step 3: commit（投稿はしない）**

```bash
git add docs/plans/2026-07-18-estalloc-or-mruby-bug-report.md docs/plans/2026-07-18-estalloc-sweep-log.md
git commit -m "docs: upstream bug report draft with deterministic repro (unposted)"
```
**投稿は user 承認必須。この計画では投稿しない。**

---

### Task 10: 完了基準ゲート — 実 example が実 teardown で Simulator 動作

**Model:** haiku（observe）＋ opus（検証判定）

**Files:**
- Modify: sweep log（最終検証結果）

- [ ] **Step 1: 本流（worktree でなく調査ブランチの最終状態）で公式パイプラインを回す**

Run:
```bash
SIM_UDID=<udid> RBENV_VERSION=4.0.5 rake determinism:ios:repl 2>&1 | tail -2
SIM_UDID=<udid> RBENV_VERSION=4.0.5 rake ios 2>&1 | tail -10        # lib->gen->build->run
SIM_UDID=<udid> RBENV_VERSION=4.0.5 rake ios:repl:observe 2>&1 | tail -5
```
Expected:
- 9-A の場合: `mrb_close` 復活済みで `observe repl: {ok=>5}` + GOLDEN match + DETERMINISTIC ok。
- 9-B の場合: WA 残置で `observe repl: {ok=>5}` + GOLDEN match（真因は upstream 草稿で記録済み）。

- [ ] **Step 2: sweep log に完了判定を記録**

REQUIRED SUB-SKILL: `superpowers:verification-before-completion` で、observe ログ実体を根拠に完了を判定（未検証を完了と言わない）。sweep log に最終 (hash, observe tally, golden 一致) を記録。

- [ ] **Step 3: commit**

```bash
git add docs/plans/2026-07-18-estalloc-sweep-log.md
git commit -m "docs(debug): completion gate — real example runs on Simulator with real teardown"
```

**merge の提案はしない。user が実機動作確認完了を宣言するまで merge の話題を出さない。**

---

### Task 11: 公式ビルド方式の版管理を確定

**Model:** sonnet（doc/コメント）＋ opus（レビュー）

**Files:**
- Modify: `README.md` / `README_jp.md`（`determinism:ios:repl` と `ios:repl:observe` を公式ターゲットとして記載）
- Modify: `CLAUDE.md`（決定論ビルド + observe が公式であることと env epoch 凍結の運用を追記）
- Delete/更新: 古い task list（Task #1-5 の estalloc 旧 Phase）と `HANDOFF.md` の交絡結論を最新に整合

- [ ] **Step 1: README に公式ターゲットを記載**

`determinism:ios:repl`（決定論検証）と `ios:repl:observe`（example-works + crash 観測、`SIM_UDID`/`OBSERVE_N`）を、既存の `rake ios` 節の近くに追記。将来 macOS/watchOS/visionOS へ `define_ios_example`/platform namespace の型で拡張する旨を 1 行添える（今回は実装しない）。

- [ ] **Step 2: commit**

```bash
git add README.md README_jp.md CLAUDE.md
git commit -m "docs: document official determinism + observe targets"
```

---

## Self-Review（記入済み）

- **Spec coverage:** ①=Task4, ②=Task5, ③=Task5+6, ④=Task3, ⑤=Task7+8, ⑥=Task9A/9B+10。公式化=Task11。完了基準=Task10。model 配分=各 Task 冒頭。すべて対応済み。
- **Placeholder:** 事実未確定部（golden 文字列・候補 commit・UDID）は「Task N で採取した実値で埋める」手順として具体化し、TBD を残さない。rake コードは実コードを記載。
- **型整合:** `ios:repl:observe` の判定キー（`:ok`/`:crash`）・`SIM_UDID`/`OBSERVE_N`・`determinism:ios:repl` の hash 比較は全 Task で一貫。observe の golden ファイル名 `#{name}_golden.txt` を Task5/9/10 で統一。
