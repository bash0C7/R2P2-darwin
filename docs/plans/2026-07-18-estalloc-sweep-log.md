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
