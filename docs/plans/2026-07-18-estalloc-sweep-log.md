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
