# R2P2-darwin 無罪証明プロトコル — 実装 plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development で
> task 単位に実行する。各 task の実行 subagent は **Sonnet**（Agent tool, `model: "sonnet"`）
> を指定し、subagent には観測事実のみを返させる。ゲート判定（棄却成否・次 task への進行・
> 中断）は main loop（Fable）が行う。Steps は checkbox (`- [ ]`) で追跡する。

**Goal:** spec（`docs/plans/2026-07-18-r2p2-darwin-innocence-proof-design.md`）で定義した
H0-a / H0-b の棄却テストを実行し、R2P2-darwin の無罪を証明または反証する。

**Architecture:** Phase A で macOS host 上に iOS と同一の VM ライフサイクル再現系を作り
欠陥を行レベル特定 → B で iOS crash との同一性を計測同定 → C で API 契約監査 →
D で「vendor のみ最小パッチ + 無変更 HEAD」の反実仮想テスト → E で upstream 確認と issue 起草。

**Tech Stack:** clang / lldb / rake（vendor picoruby build system）/ xcodebuild / simctl

**前提となるディスク状態（2026-07-18 時点で確認済み）:**
- main repo: branch `main`, HEAD `4117e4d`, working tree clean
- `vendor/picoruby`: `port-darwin` @ `8bafbb2a`, clean
- `build/host/lib/libmruby.a`: `build_config/r2p2-picoruby-darwin.rb`（フル gembox +
  estalloc + POSIX/DARWIN 両 define）でクリーンビルド済み
- 起動済み Simulator `bisect-1` UDID `B82234B5-50A7-40FD-81EE-47CC9BEA7C2C`
- bundle id: `com.bash0c7.picoruby.PicoRubyRunner`
- iOS 100% 再現手順: `rake ios:lib ios:gen ios:build` で作った app を Simulator で起動
  するだけ（`.onAppear` が `repl_eval("puts \"hello #{1 + 2}\"")` 相当を実行して crash）

**全 task 共通の制約:**
- `vendor/picoruby` への commit 禁止。変更は working tree のみ、終了時に復元。
- rake 実行時は `export RBENV_VERSION=4.0.5`（/tmp で作業する場合の rbenv フォールバック事故防止）。
- subagent は「crash した/しない・出力・診断行」を生データで報告する。原因の断定はしない。

---

## Phase A: macOS host での行レベル欠陥特定

### Task 1: bridge をそのままリンクした host ハーネスの作成と初回実行

**Files:**
- Create: `/tmp/innocence/main.c`
- 参照のみ（変更禁止）: `bridge/picoruby_bridge.c`, `bridge/picoruby_bridge.h`

ハーネス独自コードは `main()` だけにし、テスト対象は `bridge/picoruby_bridge.c`
**そのもの**をコンパイルする（忠実性の議論を排除するため、bridge の写しを作らない）。

- [ ] **Step 1: main.c を書く**

```c
#include <stdio.h>
#include <stdlib.h>
#include "picoruby_bridge.h"

int main(int argc, char **argv) {
  int n = argc > 1 ? atoi(argv[1]) : 1;
  const char *src = argc > 2 ? argv[2] : "puts \"hello #{1 + 2}\"";
  for (int i = 0; i < n; i++) {
    fprintf(stderr, "[harness] eval %d begin\n", i);
    char *out = repl_eval(src);
    fprintf(stderr, "[harness] eval %d end: %s\n", i, out ? out : "(null)");
    free(out);
  }
  fprintf(stderr, "HARNESS_DONE\n");
  return 0;
}
```

`repl_eval` の宣言が `bridge/picoruby_bridge.h` に無い場合は
`extern char *repl_eval(const char *src);` を直接書く。

- [ ] **Step 2: コンパイル（define は host lib と完全一致させる）**

```bash
mkdir -p /tmp/innocence
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
clang -g -O0 -o /tmp/innocence/harness \
  bridge/picoruby_bridge.c /tmp/innocence/main.c \
  -I build/host/include \
  -I bridge \
  -I vendor/picoruby/include \
  -I vendor/picoruby/mrbgems/picoruby-mruby/lib/mruby/include \
  -I vendor/picoruby/mrbgems/picoruby-mruby/lib/mruby/mrbgems/mruby-task/include \
  -I vendor/picoruby/mrbgems/mruby-compiler/include \
  -I vendor/picoruby/mrbgems/picoruby-mruby/lib/mruby/mrbgems/mruby-compiler/include \
  -D MRB_TICK_UNIT=4 -D MRB_TIMESLICE_TICK_COUNT=3 \
  -D PICORB_ALLOC_ALIGN=8 -D PICORB_ALLOC_ESTALLOC \
  -D PICORB_PLATFORM_POSIX -D PICORB_PLATFORM_DARWIN \
  -D MRB_INT64 -D MRB_NO_BOXING -D MRB_UTF8_STRING \
  -D MRB_BASELINE_PROFILE=1 \
  -D PICORB_VM_MRUBY -D MRB_USE_TASK_SCHEDULER \
  build/host/lib/libmruby.a \
  -L"$(brew --prefix openssl@3)/lib" -lssl -lcrypto
```

期待: exit 0。リンク未解決が出た場合は不足シンボルを報告して停止（勝手にスタブを
書かない — 不足はハーネス設計の誤りを示す事実として扱う）。

- [ ] **Step 3: 実行（1 回 eval / 5 回 eval の 2 通り）**

```bash
/tmp/innocence/harness 1; echo "exit=$?"
/tmp/innocence/harness 5; echo "exit=$?"
```

期待観測（どちらかに分岐）:
- **crash する**（SIGSEGV / abort、`HARNESS_DONE` 未到達）→ Task 2 へ。
- **crash しない** → 観測を記録し Task 4（iOS フォールバック）へ。

- [ ] **Step 4: crash した場合、素の backtrace を採取**

```bash
lldb --batch -o run -o bt -o quit -- /tmp/innocence/harness 1 2>&1 | tail -40
```

`est_free` / `remove_free_block` / `mrb_close` が backtrace に含まれるか（iOS crash との
シグネチャ一致の一次確認）を記録する。

### Task 2: ESTALLOC_DEBUG 付き host lib のリビルドと診断採取

**Files:**
- Create: `/tmp/innocence/r2p2-picoruby-darwin-debug.rb`
- 上書き: `build/host/`（デバッグ lib で上書き。後続 task で通常ビルドに戻せる）

`vendor/picoruby/mrbgems/picoruby-mruby/mrbgem.rake` は `PICORB_DEBUG` define があると
`ESTALLOC_DEBUG=1` を注入する（estalloc の sanity check / 二重解放検出が有効になる）。

- [ ] **Step 1: デバッグ用 build config を作る**

```bash
cp build_config/r2p2-picoruby-darwin.rb /tmp/innocence/r2p2-picoruby-darwin-debug.rb
```

`/tmp/innocence/r2p2-picoruby-darwin-debug.rb` の `conf.picoruby` の**前**に 2 行追加:

```ruby
  conf.cc.defines << "PICORB_DEBUG"
  conf.cc.flags << "-g" << "-O0"
```

- [ ] **Step 2: デバッグ lib をビルド**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
rm -rf build/host
export RBENV_VERSION=4.0.5
MRUBY_CONFIG=/tmp/innocence/r2p2-picoruby-darwin-debug.rb rake macos:build 2>&1 | tail -5
ls build/host/lib/libmruby.a
```

期待: ビルド成功、libmruby.a 生成。

- [ ] **Step 3: ハーネス再コンパイル・再実行**

Task 1 Step 2 のコンパイルコマンドを再実行（lib が差し替わったため）し、
`/tmp/innocence/harness 1` を実行。

期待観測: `ESTALLOC_DEBUG` の診断出力（sanity check 失敗・double free 検出メッセージ）
または assert abort。**メッセージ全文と、それが指す estalloc 内の検査箇所**を記録する。

- [ ] **Step 4: lldb で欠陥行を特定**

診断メッセージだけで「どの gem のどの free 呼び出しが二重解放したか」まで確定しない
場合、lldb で診断発火点に breakpoint を置き、呼び出し元 Ruby/C 経路を full backtrace で
採取する:

```bash
lldb --batch \
  -o "b est_sanity_check" \
  -o run -o bt -o quit \
  -- /tmp/innocence/harness 1 2>&1 | tail -60
```

（breakpoint 名は Step 3 の診断実装を読んで実在の関数名に合わせる。目的は
**「二重解放/破損を起こした free の呼び出し元」の関数・ファイル・行**の確定。）

**Task 2 の完了条件:** 欠陥の行レベル特定（`<file>:<line>` と破損メカニズムの記述）。
特定した起点が `bridge/picoruby_bridge.c` 側だった場合は **H0-a 確証**として停止し報告する。

### Task 3: 通常 host lib への復元

- [ ] **Step 1: 通常ビルドに戻す**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
rm -rf build/host
export RBENV_VERSION=4.0.5
rake macos:build 2>&1 | tail -3
```

期待: 成功。（Phase D の iOS ビルドは別 target `ios-repl-sim` だが、host の mrbc を
使うため通常状態に戻しておく。）

### Task 4（条件付き: Task 1 で host 非再現の場合のみ）: iOS 側での行レベル特定

- [ ] **Step 1: iOS repl-sim build config にデバッグ define を足した一時 config を作る**

```bash
cp build_config/r2p2-picoruby-ios-repl-sim.rb /tmp/innocence/ios-repl-sim-debug.rb
```

`conf.picoruby` の前に `conf.cc.defines << "PICORB_DEBUG"` と
`conf.cc.flags << "-g" << "-O0"` を追加（Task 2 Step 1 と同形）。

- [ ] **Step 2: iOS lib を一時 config でビルドし app を再ビルド**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
MRUBY_CONFIG=/tmp/innocence/ios-repl-sim-debug.rb rake ios:lib 2>&1 | tail -3
rake ios:gen ios:build 2>&1 | tail -3
```

（`ios:lib` が `MRUBY_CONFIG` を尊重しない場合は Rakefile の `stage_libmruby`
呼び出しを読み、config 指定の実経路を確認して報告 — build_config 本体は変更しない。）

- [ ] **Step 3: lldb attach で診断発火点の backtrace を採取**

```bash
UDID=B82234B5-50A7-40FD-81EE-47CC9BEA7C2C
APP=$(ls -d build/ios-repl-app/Build/Products/Debug-iphonesimulator/PicoRubyRunner.app)
xcrun simctl install $UDID "$APP"
xcrun simctl launch --wait-for-debugger $UDID com.bash0c7.picoruby.PicoRubyRunner
# 別プロセスで: lldb -o "process attach --pid <PID>" -o "b <診断関数>" -o continue ...
```

**完了条件は Task 2 と同一**（行レベル特定）。

---

## Phase B: iOS crash との同一性同定

### Task 5: 特定行と iOS 破損経路の照合

- [ ] **Step 1: 既知の iOS 破損経路と突合**

前 session の lldb watchpoint 計測で iOS の破損経路は
「ENV hash 構築 → io-console メソッドテーブル拡張 → `mrb_env_unshare` →
hash-ext ROM メソッドテーブル初期化 → `mrb_close` 中の GC free」と記録済み
（`HANDOFF.md` §2）。Phase A で特定した欠陥行がこの経路上の関数に属するかを、
ソース参照で確認する。

- [ ] **Step 2: 属さない場合は iOS 上で直接計測**

Task 4 の手順（デバッグ iOS build + lldb）で iOS 側の診断発火点を採取し、
Phase A の特定行と一致するかを確認する。

**完了条件:** 「host で特定した欠陥行が iOS crash の欠陥行と同一」の計測的根拠。
不一致なら Phase A へ差し戻し（host の crash は別バグとして記録だけ残す）。

---

## Phase C: API 契約監査（H0-b）

### Task 6: bridge が呼ぶ vendor API の契約突合

- [ ] **Step 1: 証拠収集（Sonnet subagent、読み取りのみ）**

対象 API: `mrb_open_with_custom_alloc` / `mrc_ccontext_new` / `mrc_ccontext_filename` /
`mrc_load_string_cxt` / `mrc_create_task` / `mrb_task_run` / `mrb_task_value` /
`mrc_ccontext_free` / `mrb_close`。それぞれについて:

1. 宣言ヘッダのコメント・契約記述
2. vendor tree 内の全呼び出し例（`grep -rn` で列挙し、bridge と同順・同組み合わせの
   利用が vendor 内に存在するか）
3. `mrb_close` について: upstream mruby での意味論（「open したら close する」が標準契約）、
   vendor 純正バイナリが回避している事実（`picoruby.c` の `// TODO: fix segv`）、
   `picoruby-picotest` 等のテスト系 gem が `mrb_close` を呼ぶか

- [ ] **Step 2: 判定（Fable main loop が行う）**

判定基準: bridge の各呼び出しが (a) 公開ヘッダの契約に反していない、(b) vendor 内に
同等利用の先例がある or upstream mruby の標準契約に合致する — の両方を満たせば契約内。
`mrb_close` が「picoruby では呼んではならない API」と文書化されていれば H0-b 棄却失敗。
単に vendor 自身がバグを回避してコメントアウトしているだけなら、契約内利用が vendor の
欠陥を踏んだと解釈する（判定根拠を明文で記録）。

---

## Phase D: 反実仮想テスト（H0-a）

### Task 7: ベースライン再確認（対照群）

- [ ] **Step 1: 無変更 HEAD で iOS app をビルド**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
git status --short   # 空であること（HANDOFF.md は untracked 想定内）
export RBENV_VERSION=4.0.5
rake ios:lib ios:gen ios:build 2>&1 | tail -3
```

- [ ] **Step 2: 既存 crash log を退避し、3 回起動して 3/3 crash を確認**

```bash
UDID=B82234B5-50A7-40FD-81EE-47CC9BEA7C2C
xcrun simctl bootstatus $UDID -b
APP=$(ls -d build/ios-repl-app/Build/Products/Debug-iphonesimulator/PicoRubyRunner.app)
mkdir -p /tmp/innocence/ips-archive
mv ~/Library/Logs/DiagnosticReports/PicoRubyRunner*.ips /tmp/innocence/ips-archive/ 2>/dev/null
xcrun simctl uninstall $UDID com.bash0c7.picoruby.PicoRubyRunner 2>/dev/null
xcrun simctl install $UDID "$APP"
for i in 1 2 3; do
  xcrun simctl launch $UDID com.bash0c7.picoruby.PicoRubyRunner
  sleep 10
  pgrep -x PicoRubyRunner >/dev/null && echo "run$i: ALIVE" || echo "run$i: DEAD"
  xcrun simctl terminate $UDID com.bash0c7.picoruby.PicoRubyRunner 2>/dev/null
done
ls ~/Library/Logs/DiagnosticReports/PicoRubyRunner*.ips 2>/dev/null | wc -l
```

期待: 3 回とも `DEAD`（crash）。ここで crash しなければ**再現系が壊れている**ので
停止して報告（パッチ検証は無意味になる）。

### Task 8: vendor 最小パッチの適用（working tree のみ）

- [ ] **Step 1: パッチ内容の確定**

Phase A で特定した欠陥行に対する最小修正を、**挙動変更が欠陥修正のみに閉じる形**で
設計する（リファクタ・整形・追加の防御コードを混ぜない）。パッチの diff 全文を
記録に残す。

- [ ] **Step 2: working tree に適用（commit しない）**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin/vendor/picoruby
git status --short   # 適用前: 空
# （Edit tool で該当ファイルを修正）
git diff             # 適用後: パッチ diff を記録
```

### Task 9: 無変更 HEAD の再ビルドと 10 回起動テスト

- [ ] **Step 1: R2P2-darwin 側が無変更であることを検証**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
git status --short          # vendor 以外の変更が無いこと
git -C vendor/picoruby diff --stat   # パッチのみ
```

- [ ] **Step 2: iOS lib と app を再ビルド**

```bash
rm -rf build/ios-repl-sim build/ios-repl-app examples/ios/repl/Vendor
export RBENV_VERSION=4.0.5
rake ios:lib ios:gen ios:build 2>&1 | tail -3
```

（クリーンビルド必須 — stale object でパッチが混ざらない/混ざったままを防ぐ。）

- [ ] **Step 3: 10 回連続起動**

Task 7 Step 2 と同じ手順で、ループを `for i in $(seq 1 10)` にして実行。

**判定（Fable）:** 10/10 `ALIVE` かつ新規 .ips が 0 件 → **H0-a 棄却（無罪確定）**。
1 回でも `DEAD` → 棄却失敗。crash log を採取し、Phase A の特定が不完全か
R2P2-darwin 側に別の必要原因があるかの切り分けに戻る。

### Task 10: vendor working tree の復元

- [ ] **Step 1: 復元と確認**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin/vendor/picoruby
git checkout -- .
git status --short   # 空であること
```

（判定結果にかかわらず必ず実行する。パッチ diff は Task 8 Step 2 で記録済み。）

---

## Phase E: upstream 確認と issue 起草（無罪確定後のみ）

### Task 11: upstream 同一欠陥の確認

- [ ] **Step 1: upstream の該当コードを取得して突合**

```bash
cd /tmp/innocence
gh repo clone picoruby/picoruby upstream-picoruby -- --depth 1 2>/dev/null \
  || git clone --depth 1 https://github.com/picoruby/picoruby upstream-picoruby
# Phase A で特定した <file>:<line> 相当箇所を upstream 側で読み、同一欠陥か確認
```

判定: 同一欠陥あり → upstream issue 対象。fork（`port-darwin`）でのみ発生 →
fork 側課題として整理（issue 先が変わる）。

### Task 12: issue 草稿の作成

- [ ] **Step 1: 草稿を書く**

Create: `/tmp/innocence/picoruby-issue-draft.md`。含める内容:
1. 症状（crash シグネチャ、環境）
2. 最小再現（Task 1 のハーネス — R2P2-darwin 非依存の形に整えた版）
3. root cause（欠陥行と破損メカニズム）
4. パッチ案（Task 8 の diff）
5. 補足: vendor 純正 `picoruby.c` の `// TODO: fix segv` との関係

- [ ] **Step 2: user へ提示**

**issue の投稿は user 承認必須。**草稿 path を報告して停止する。

---

## Self-review 済み確認事項

- 全 task に実コマンド・実コードを記載（Task 8 のパッチ内容のみ Phase A の出力に
  依存するため手順・制約・記録要件で規定 — これは実験プロトコルの依存関係であり
  placeholder ではない）
- ゲート判定はすべて main loop（Fable）に留保、subagent は観測のみ
- vendor 復元（Task 10）は判定結果にかかわらず必ず実行
- 停止条件: Task 2（bridge 起点判明）/ Task 6（契約外判明）/ Task 7（ベースライン
  非再現）/ Task 9（crash 残存）
