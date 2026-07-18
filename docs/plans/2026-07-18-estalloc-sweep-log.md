# estalloc sweep log

## Pins (Task 1)
- repo HEAD: 76d517f55e3473b9dc8ff274e517f9af8ddce16d
- vendor/picoruby ref: 8bafbb2a405d3370bc9003280c00f6beebe97a74 (PICORUBY_REF=port-darwin)
- estalloc submodule: mrbgems/picoruby-mruby/lib/estalloc @ 971b79376d6592f6f805b8ec4e7ce1589b12163c
- ruby: 4.0.5 ✓
- frozen Simulator: iPhone 17 Pro UDID=022CC935-D50B-4790-978F-E4CA1DD0F5DC — Booted, re-creation/deletion/factory-reset forbidden, epoch deterministic

## Repro trigger + golden (Task 2)
- 起動で走る経路: repl_eval 自動（UI 入力不要）。ContentView が `.onAppear { run() }`（ContentView.swift:39）で起動時に run() を呼び、run() は background thread で `repl_eval(self.source)`（ContentView.swift:47）を実行。`self.source` の初期値は `puts "hello #{1 + 2}"`（ContentView.swift:4）で onAppear 時点ではこの default のまま。repl example は `vm_open`/`vm_call`/`vm_close` を一切呼ばない（ContentView.swift は repl_eval と free のみ使用）ため boot Ruby も存在しない。crash signature の repl_eval と一致。
- mrb_close teardown 到達条件: 起動だけで到達。repl_eval が `.onAppear` で自動実行されるため、picoruby_bridge.c:113 の `/* mrb_close(mrb); */` を復活させれば起動〜最初の自動 eval のみで teardown 経路（mrb_close→est_free）に入る。UI 入力・ボタン tap は不要。vm_close（picoruby_bridge.c:213）はこの example では未到達（vm_open 経路を使わないため）。
- 正常時の決定論出力(golden 候補): `hello 3`（出所: ContentView.swift:4 の default source `puts "hello #{1 + 2}"` を repl_eval が PUTS_SHIM 付きで eval し stdout へ）。os_log/NSLog 側は `[PicoRubyRunner] output:` の後に本文が続く（ContentView.swift:57 の NSLog フォーマット `[PicoRubyRunner] output:\n%@`、および ContentView.swift:58 の print）。observe の golden 判定用固定文字列: 出力本文中の `hello 3`、ログ行 prefix `[PicoRubyRunner] output:`。eval 失敗時は `(VM failed to start)`（ContentView.swift:50）。
- observe を UI 入力なしで crash 到達させる手段: 選択 = (a) 起動だけで足りる。picoruby_bridge.c:113 のコメントアウト `mrb_close(mrb)` を uncomment して repl example を rebuild し、Simulator (UDID=022CC935-D50B-4790-978F-E4CA1DD0F5DC) に install & launch するだけで、`.onAppear` の自動 repl_eval → mrb_close → est_free で crash が決定論的に再現する。boot Ruby 追加や simctl 入力送出は不要（この example に boot Ruby / vm_open 経路が無いため (b) は該当せず、(c) も不要）。observe は起動後ログで golden `hello 3` の不在 + est_free/EXC_BAD_ACCESS crash を確認する。

## Observations (Task 2+)
*TBD: sweep results*

## History-terrain map (Task 3)

以下は当 session の git 調査（静的解析）に基づく。ビルド・実機実行はしていないため
crash on/off 予測は仮説であり未検証。

### 候補 commit（時系列）
| commit | 日付 | 触った軸 | crash 仮説への関与 |
|---|---|---|---|
| aa776f1 | 2026-06-20 | build_config (scaffold, PICORB_PLATFORM_POSIX 導入) + Rakefile PICORUBY_REF | 以降 libmruby 側は posix 判定 → BASELINE profile (heap 1024, method-cache on) で compile される起点 |
| 75ac861 | 2026-06-21 | bridge picoruby_eval 新規（`mrb_close` 初出、HEAP_SIZE/calloc/mrb_open_with_custom_alloc） | teardown 経路の元。mrb_close がこの時点から存在 |
| c9e0d1b | 2026-06-21 | app project.yml 新規（`app/project.yml`）— GCC_PREPROCESSOR_DEFINITIONS に `MRB_CONSTRAINED_BASELINE_PROFILE=1` と `MRB_HEAP_PAGE_SIZE=128` を初出で宣言 | app(bridge) 側が CONSTRAINED/128、libmruby 側は BASELINE/1024 → profile 不一致（sizeof(mrb_state)/heap page layout 差）の起点。**mismatch 3 要素が揃う最古の commit** |
| e314a0d | 2026-06-21 | bridge picoruby_eval → repl_eval rename | crash signature の関数名確定 |
| b9d2dd3 | 2026-06-21 | bridge persistent VM API (vm_open/vm_call/vm_close, run_irep 抽出) | repl_eval の mrb_close は温存。vm_close にも mrb_close 追加（repl example では未到達） |
| acfd68c | 2026-06-21 | bridge vm_call fd-guard / vm_open error path | mrb_close 温存 |
| f4ac624 | 2026-06-26 | build_config rename ios-{sim,device}→ios-repl-{sim,device} | 命名のみ |
| 0548b9e | 2026-06-26 | build_config full-REPL 化（posix?=true + darwin port-chain, gembox 拡張） | posix 判定を確定させる現行 canonical build_config。BASELINE profile 分岐を確定 |
| c27c1c3 | 2026-07-03 | build_config mruby-compiler/mrbc rename 追随 | gem 名のみ |
| 5736c4d | 2026-07-03 | project.yml platform-first 移動（examples/repl→examples/ios/repl） | 内容不変の rename（defines は c9e0d1b 由来） |
| 95d70ee | 2026-07-03 | project.yml (rake 追随の修正) | defines 不変 |
| 37f9147 | 2026-07-12 | bridge + build_config コメント現在形化 | コメントのみ、コード不変 |
| 558b77a | 2026-07-16 | bridge exception-surfacing dedupe / fd-guard 非対称修正 | **mrb_close 依然 active**。workaround 直前の bad 端候補 |
| 5e770ef / b64a449 | 2026-07-17 | project.yml Team ID placeholder / Rakefile repl 統合 | defines 不変 |
| d43aa7f | 2026-07-18 | bridge `mrb_close` を repl_eval と vm_close で comment out（workaround） | crash on/off の実質スイッチ。ここで crash OFF |

### define 不一致の事実
判定根拠: build_config は PICORB_PLATFORM_POSIX を定義（`conf.cc.defines`）→
`vendor/picoruby/lib/picoruby/build.rb:135 posix? = cc.defines.include?("PICORB_PLATFORM_POSIX")`
が真 → `mrbgems/picoruby-mruby/mrbgem.rake:36` の分岐で libmruby は
`if wasm? || posix?` の**真側**に入り `MRB_BASELINE_PROFILE=1` を build.defines に積む
（CONSTRAINED も HEAP_PAGE_SIZE も設定しない）。app 側 project.yml は真逆の
microcontroller profile 値をハードコードしている。

- **MRB_USE_TASK_SCHEDULER**: build_config=無（明示せず）/ project.yml=有(`=1`) / picoruby default=有。`include/picoruby.h:84-85` が `#if !defined → #define 1`、加えて `mruby-task/mrbgem.rake:7` が build.defines に積む。→ **両側 on で一致、mismatch でない**
- **MRB_USE_VM_SWITCH_DISPATCH**: build_config=無 / project.yml=有(`=1`) / picoruby default=有。`include/picoruby.h:87-88` と `mrbconf.h:187`/`src/vm.c:1580` で default on。VM dispatch のみで struct layout 非依存。→ **両側 on で一致**
- **MRB_CONSTRAINED_BASELINE_PROFILE**: build_config=**無**（posix 分岐のため代わりに `MRB_BASELINE_PROFILE=1`）/ project.yml=**有**(`=1`) / picoruby default=posix では付かない（非 posix の else 分岐でのみ `mrbgem.rake:45` が build.defines に積む）。→ **不一致**。`mrbgem.rake:34-35` のコメントが「CONSTRAINED/BASELINE は MRB_NO_METHOD_CACHE を定義し sizeof(mrb_state) を変えるので build-wide define であるべき」と明記。app 側だけ CONSTRAINED=NO_METHOD_CACHE、libmruby 側は BASELINE=cache 有 → **sizeof(mrb_state) と field offset が両側で食い違う ABI mismatch**
- **MRB_HEAP_PAGE_SIZE**: build_config=**無**（posix 分岐で未設定 → `src/gc.c:165-166` の default 1024）/ project.yml=**有**(`=128`) / picoruby default=非 posix のとき `mrbgem.rake:44` が `cc.defines << 128`、posix のときは未設定で 1024。→ **不一致（libmruby=1024 vs app=128）**。`gc.c:175 RVALUE objects[MRB_HEAP_PAGE_SIZE]` の heap page struct が両側で別 layout

要約: 4 define のうち TASK_SCHEDULER と VM_SWITCH_DISPATCH は両側一致で軸から除外。
**CONSTRAINED_BASELINE_PROFILE と HEAP_PAGE_SIZE の 2 つが build_config(posix→BASELINE/1024)
と project.yml(CONSTRAINED/128) で食い違う** — これが libmruby↔app 境界の struct layout
不一致（mrb_state と heap page）の実体。

### bisect レンジ
変える変数は commit のみ、build-param は各 commit 自身の canonical tree（現 build_config）に固定。

- **good 端候補（crash しないと予想）: d43aa7f（HEAD 側 workaround commit）** — repl_eval/vm_close の
  `mrb_close` が comment out されており teardown→est_free に入らない。canonical build で crash OFF と予想
- **bad 端候補（crash すると予想）: 558b77a** — workaround 直前。repl_eval に `mrb_close(mrb);` が active
  （`git show 558b77a:bridge/picoruby_bridge.c` の行109で確認）、build_config は posix→BASELINE/1024、
  project.yml は CONSTRAINED/128 で 3 要素が揃う。canonical build で crash 再現と予想
- このレンジ内 d43aa7f↔558b77a の差分は実質 `mrb_close` の一行のみ。commit 軸 bisect は
  「mrb_close が crash の on/off スイッチ」を確認するに留まり、**真の regression を局所化しない**：
  crash の 3 要素（mrb_close active・libmruby BASELINE/1024・app CONSTRAINED/128）は
  app 誕生の c9e0d1b(2026-06-21) 以降ずっと連続して存在し、repo 履歴内に「要素が揃う前」の
  non-crash commit が存在しない（c9e0d1b で 3 要素が初めて同時成立、以降 d43aa7f まで不変）。
  → 弁別軸は commit ではなく build-param（define）側。CONSTRAINED_BASELINE_PROFILE と
  HEAP_PAGE_SIZE の単一変数コントラスト（Task 8 の param 軸）が本命。

## Crash baseline (Task 6) — branch debug/crash-baseline
- 変更: bridge/picoruby_bridge.c の mrb_close 復活（repl_eval 内 L113 相当、vm_close 内 L213 相当）。
  build-param（build_config / project.yml）は一切変更せず canonical のまま。
- observe 結果: `{unknown: 5}` over 5 runs（`rake ios:repl:observe`、frozen Sim 022CC935）——
  rake の CRASH 分類自体は 5 回とも fire しなかった（下記「observe 分類の不発」参照）。
- crash 判定: **決定論的 crash**。observe のタリーは `unknown` だが、host 側
  `~/Library/Logs/DiagnosticReports/PicoRubyRunner-2026-07-18-2207xx.ips` を突き合わせると、
  5 回の launch ウィンドウ（22:07:55 〜 22:08:19）に対し新規 .ips が **ちょうど 5 件**生成されており
  （220755 / 220759 / 220806 / 220812 / 220819）、全件が同一シグネチャ:
  `exception.type=EXC_BAD_ACCESS, signal=SIGSEGV, subtype=KERN_INVALID_ADDRESS at 0x0000000000000022`。
  5/5 一致で non-deterministic ではない。
- crash report: `~/Library/Logs/DiagnosticReports/PicoRubyRunner-2026-07-18-220819.ips`
  （他 4 件も同一）。`xcrun atos -o build/ios-repl-app/.../PicoRubyRunner.debug.dylib -l 0x0 <offset>`
  で faultingThread をシンボリケートすると:
  ```
  remove_free_block (in PicoRubyRunner.debug.dylib) + 0
  est_free (in PicoRubyRunner.debug.dylib) + 128
  closure #1 in ContentView.run() (in PicoRubyRunner.debug.dylib)  (ContentView.swift:47)
  thunk for @escaping @callee_guaranteed @Sendable () -> ()
  ```
  ContentView.swift:47 は `guard let cstr = repl_eval(self.source) else { ... }` の呼び出し行。
  仮説どおり `remove_free_block ← est_free ← repl_eval`（mrb_close 経由の teardown crash）が実測で確認できた。
- observe CRASH 分類経路の発火: **しなかった**（Task 5 の検証結果 = バグを検出）。
  `Rakefile` の `observe()` が見る `crash_dir` は
  `~/Library/Developer/CoreSimulator/Devices/<udid>/data/Library/Logs/DiagnosticReports` だが、
  このディレクトリ自体が今回の環境（macOS 26.5.2 + この frozen Sim）に**存在しない**
  （実測: `ls` が `No such file or directory`）。実際の crash report は per-device data dir ではなく
  **host 側** `~/Library/Logs/DiagnosticReports` に落ちる。加えて output ベースの fallback
  （`EXC_BAD_ACCESS|est_free|remove_free_block` を stdout/stderr から grep）も、
  `simctl launch --console-pty` が捕捉したログが `com.bash0c7.picoruby.PicoRubyRunner: <pid>` のみで
  NSLog/print 出力が一切無い（クラッシュが `run()` 内の最初の `repl_eval` 呼び出し直後・print 前に
  発生するため）まま不発。結果、5 回とも `crashed=false, ok=false` → `:unknown` に落ちた。
  → **Task 5 の observe は crash_dir のパスが誤りで、実クラッシュを見逃す**（このタスクで判明した
  新規の欠陥。Task 7 以降の bisect で observe を使うなら先に crash_dir 修正が要る）。

## Task 7 (commit 軸) 決着 — 1 行記録
crash 要素（mrb_close active・libmruby BASELINE/1024・app CONSTRAINED/128）は app 誕生の
c9e0d1b(2026-06-21) 以降ずっと連続して存在し、要素が揃う前の non-crash commit が repo 履歴に無い。
コード軸の境界は mrb_close 一行のみ（Task 5: ok ↔ Task 6: crash で実証済み）。→ bisect は無意味、
弁別軸は param 軸（本 Task 8）。

## Param-axis controlled experiment (Task 8)

### 事前調査
- `vendor/picoruby/lib/picoruby/build.rb:135` `posix? = cc.defines.include?("PICORB_PLATFORM_POSIX")`。
  build_config が `PICORB_PLATFORM_POSIX` を立てているため `posix?` は真。
- `vendor/picoruby/mrbgems/picoruby-mruby/mrbgem.rake:36-46`: `if spec.build.wasm? || spec.build.posix?`
  の真側で `spec.build.defines << "MRB_BASELINE_PROFILE=1"`（HEAP_PAGE_SIZE は設定しない→
  `src/gc.c:165-166` の default 1024 が有効）。偽側（non-posix）でのみ `MRB_CONSTRAINED_BASELINE_PROFILE=1`
  と `MRB_HEAP_PAGE_SIZE=128`（非 O1HEAP 時）を設定。
  → **libmruby 側は現在 `MRB_BASELINE_PROFILE=1` + heap page 1024 相当で compile されている**
  （静的解析どおりで確認どおり。app 側 project.yml は `MRB_CONSTRAINED_BASELINE_PROFILE=1` +
  `MRB_HEAP_PAGE_SIZE=128`）。
- `mrbconf.h:212-227` は `#if defined(MRB_CONSTRAINED_BASELINE_PROFILE) ... #elif defined(MRB_BASELINE_PROFILE)`
  の順で判定するため、build_config に `conf.cc.defines << "MRB_CONSTRAINED_BASELINE_PROFILE=1"` を
  追加するだけで足りる（mrbgem.rake が併せて `MRB_BASELINE_PROFILE=1` も積むが、`#if`/`#elif` の
  順序上 CONSTRAINED 側が勝つため衝突しない）。HEAP_PAGE_SIZE も同様に `conf.cc.defines <<
  "MRB_HEAP_PAGE_SIZE=128"` を直接追加するだけで posix 分岐の未設定を上書きできる。

### 方法論上の重要な落とし穴（実験前に発覚・修正）
mrbgem.rake の `file obj => [file] do ... end`（picoruby-mruby 配下の `lib/mruby/src/*.c` 全般、
gc.c 含む）は **source ファイルの mtime にのみ依存し、build_config の mtime/内容には依存しない**。
build_config の define だけ変えて `rake ios:repl:lib` を再実行しても、既存の `build/ios-repl-sim/`
下の `.o`（例: gc.o）は「up to date」と判定され **再コンパイルされない**。実際、Exp1/Exp2/Exp3 を
`rm -rf build/ios-repl-sim` 無しで実行した初回試行では、`gc.o` の mtime が define 変更前のまま
（3 回とも同一 stale object を再リンクしていただけ）と判明し、3 回とも `{crash:5}` が出たが
**これは無意味な結果**（define 変更が一切 libmruby に反映されていない）。CLAUDE.md の
「クリーンビルドで stale object を除去する際は repo 直下 build/<target>/ を消す」の通り、
各 Exp 前に `rm -rf build/ios-repl-sim` を追加してから正しく再実験した（下表は全て clean 後の結果）。

また、`ios:repl:observe` が「new crash」と認識する host 側 `.ips` は、macOS の crash reporter が
**同一プロセス名の繰り返し crash に対して既存ファイル名を再利用しつつ mtime だけ更新する**
ことがあり（filename の日時 ≠ 実際の発生時刻）、1 回だけ `{unknown:1, crash:4}` の非決定表示が
出た（Exp3 初回）。同一 build のまま observe を再実行すると `{crash:5}` に安定したため、
crash-reporter の生成レイテンシ起因の見かけ上のノイズと判断（実クラッシュは 5/5 のまま）。

### 実験結果（全て clean rebuild 後、canonical から 1 変数のみ変更、mrb_close は復活のまま）
| Exp | 変更内容（libmruby build_config のみ） | observe tally |
|---|---|---|
| baseline（変更なし、sanity re-check） | canonical（`MRB_BASELINE_PROFILE=1` 相当、heap page 1024） | `{crash: 5}` |
| Exp1 | `conf.cc.defines << "MRB_HEAP_PAGE_SIZE=128"` のみ追加 | `{crash: 5}` |
| Exp2 | `conf.cc.defines << "MRB_CONSTRAINED_BASELINE_PROFILE=1"` のみ追加 | `{crash: 5}` |
| Exp3 | Exp1 + Exp2 両方（app 側 project.yml と完全一致） | `{crash: 5}`（初回 `{unknown:1,crash:4}` → 再 observe で `{crash:5}` に安定） |

### 真因帰属
**build-param（MRB_CONSTRAINED_BASELINE_PROFILE / MRB_HEAP_PAGE_SIZE）の mismatch は真因ではない。**
libmruby 側 build_config を app 側 project.yml と完全に一致させても（Exp3）決定論的 crash
（`{crash:5}`）が残った。仮説（ABI mismatch by profile/heap-page define 不一致）は**棄却**。
mrb_close 復活済み teardown 経路での est_free crash は、profile/heap-page の define 一致とは
独立に発生する — estalloc または mruby 内部（gc.c の teardown ロジック / estalloc の
free-block 管理）側の欠陥である可能性が高い。次段は watchpoint 等での実行時観測に進む
（Task 9 以降の判断材料）。

### build_config の最終状態
実験終了後 `git checkout -- build_config/r2p2-picoruby-ios-repl-sim.rb` で baseline に復元。
`git status` で差分なしを確認済み（このコミット時点で build_config は変更していない）。

## Completion gate (Task 10) — WA restored

`debug/crash-baseline` は Task 6/7/8 の調査用に `bridge/picoruby_bridge.c` の `mrb_close`
（`repl_eval` L113 相当・`vm_close` L213 相当）を意図的に復活させていた（crash 再現用）。
調査完了（真因は estalloc/mruby 内部 teardown、build-param/ABI mismatch は棄却済み、
victim/culprit 未決着）を受け、WA（`mrb_close` を呼ばず `free(heap)`/`free(h->heap)` で
estalloc pool を丸ごと回収）を最終状態として復元した。両箇所を `/* mrb_close(...); */` へ
コメントアウトし、直前の説明コメントを「vendor estalloc defect」という断定から今回の
調査結論（決定論再現あり・ABI mismatch は対照実験で棄却・victim/culprit 未決着）に更新。
error パス（`vm_open` 失敗時、L147/160/169）の `mrb_close` は元の設計どおり変更していない。

### 手順と実測結果
```
rm -rf build/ios-repl-sim
RBENV_VERSION=4.0.5 rake ios:repl:lib ios:repl:gen ios:repl:build   # BUILD SUCCEEDED
SIM_UDID=022CC935-D50B-4790-978F-E4CA1DD0F5DC RBENV_VERSION=4.0.5 rake ios:repl:observe
```
結果: `observe repl: {ok: 5} over 5 runs`（5 runs 全て `run N: ok`）。

- 各 run の captured output に `hello 3` が 2 回出現（print と puts 経路の両方、golden と
  同一 pattern）。
- `run N: ok` のたびに `GOLDEN mismatch` と表示されたが、実体は
  `build/observe/repl_golden.txt`（22:04 保存、以前の run の PID/timestamp を含む）と
  今回の run（PID/timestamp が異なる）との diff が PID・timestamp 行のみであることを
  `diff build/observe/repl_golden.txt build/observe/repl_run1.txt` で確認済み — 内容面
  （`hello 3` を含む出力本体）は完全一致。golden mismatch は非決定要因（PID/timestamp）
  によるもので機能的な差ではない。
- `grep -l "EXC_BAD_ACCESS\|est_free\|remove_free_block" build/observe/repl_run*.txt` は
  該当なし（5 run 全てで crash signature 無し）。
- `~/Library/Logs/DiagnosticReports/` の `PicoRubyRunner-*.ips` 最新は 22:30 保存分（本 gate
  実行前の Task 8 実験由来）で、本 gate の run（22:59-23:00）以降に新規 `.ips` は生成されて
  いない — `observe` 関数の new-crash 判定（mtime >= launched_at）でも crash 無しと一致。

**完了基準達成**: WA 復元状態で `examples/ios/repl` が frozen Simulator 上で 5/5 決定論的に
正常終了（`hello 3` 捕捉・crash report 無し）。
