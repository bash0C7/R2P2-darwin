# Spec: 決定論的スイープによる `est_free` crash 真因特定

## 0. 一行

`examples/ios/repl` 起動時の `mrb_close` teardown 中 `est_free` での `EXC_BAD_ACCESS`
について、真因を〈repo commit × build パラメータ〉空間で **crash 再現が on/off する
境界**として特定する。単一状態のパッチではなく境界の因果を掴む。すべて rake の
scripted ビルドで決定論的に、各セルで実 example の正常動作を確認しながら行う。

## 1. なぜ仕切り直すか（前結論を引き継がない理由）

前セッションまでの因果的結論（estalloc 内部欠陥説 / R2P2-darwin 無罪 / ワークアラウンド
有効）は、**ビルド入力（`libmruby.a` の中身）と実行環境（Simulator の env epoch）を
統制しないまま**導かれており交絡している。同一 binary が env epoch 次第で crash したり
しなかったりし、素の rebuild だけで crash が消えた（`libmruby.a` の内容ドリフト）。
「非決定的」なのではなく **制御していない決定的入力に依存していた**。よって確定結論は
引き継がず、決定論的再現の確立から仕切り直す。

## 2. 目的と完了基準

- **目的**: 真因を〈commit × build-param〉空間の crash on/off 境界として特定し、
  正しい処置（build config 一貫化 か upstream bug report）を決める。
- **完了基準（常時ゲート）**: 実 `examples/ios/repl` が Simulator 上で、**本来の
  teardown 経路（`mrb_close` を無効化しない元コード）**のまま正しく動くこと。
  自動テスト・ビルド成功だけでは完了としない。merge の話題は user が実機確認完了を
  宣言するまで出さない。
- **決定論の規律**: 全ビルドは rake の scripted ターゲットのみ。ad-hoc clang・手作業の
  `-I`/lib 足し引き・Xcode GUI 操作を禁止。「ビルド実行の手抜き」を一切しない。

## 2.5 ビルド・検証方式は公式・版管理・多プラットフォーム拡張

このスイープで確立するビルド + 検証方式は **使い捨ての調査足場ではなく、R2P2-darwin の
公式ビルド方式**として本 repo に版管理する。iOS を皮切りに、以後 macOS / Apple Watch /
Vision Pro などへ同じ型で応用していく。

- **既存機構を更新する形で作る**。新規の並行ハーネスを別途作らない。土台は既存の
  `Rakefile`（例ごとに lib→gen→build→run を生成する `define_ios_example`）/ `rakelib/macos.rake`
  / `build_config/*.rb`。ここに決定論検証（content-hash）と example-works 自動判定を足す。
- **拡張性は既存パターンに従うことで確保**し、投機的抽象化はしない（iOS を先に完成させる）。
  `define_ios_example` の例パラメータ化・platform namespace（`macos:` / `watchos:`）という
  既存の一般化構造が、将来の macOS/watchOS/visionOS 適用の受け皿。今回はそこへ新プラットフォーム
  を足す作業はしない。
- 成果（決定論ビルド + example 検証ターゲット）は commit して公式化する。

## 3. スコープ外（YAGNI）

- 現時点で実行はしない。本 doc は設計。実行は plan 承認後の systematic-debugging で行う。
- crash と無関係な refactor・機能追加をしない。
- 新規プラットフォーム（macOS/watchOS/visionOS）の検証ターゲットを今回足さない
  （型を将来適用可能に保つのみ。iOS を先に完成）。
- bug report の投稿はしない（起草のみ、投稿は user 承認必須）。

## 4. コンポーネント（独立に理解・検証できる単位）

### ① パラメータ化ビルドセルの定義（既存 rake を更新して公式化）
`cell = (repo commit, vendor ref, build_config define 集合, gembox)`。1 つの cell を
rake で決定論的に materialize する。**既存の `Rakefile` / `build_config` を更新**して
実装し（並行ハーネスを別に作らない）、成果は公式ビルド方式として commit する。
**決定論の証明 = 同一 cell を複数回ビルドして `libmruby.a` と app binary の
content-hash が一致すること**。前セッションの「100KB ドリフト」を hash で検出し封じる。
cell 仕様と得られた hash は記録に残す。content-hash 検証は公式ターゲットとして残す。

### ② example-works ゲート（公式検証ターゲットとして版管理）
各 cell で `rake ios`（= `ios:repl:all`: lib→gen→build→run）相当を回し、example が
期待出力を出すことを **scripted に自動判定**する（目視でなく simctl のログ assertion）。
動かない cell は判定対象から除外し、その旨を記録する。この自動判定は使い捨てにせず、
**公式の example 検証ターゲット**として rake に据え、既存の `define_ios_example` /
platform namespace の型に沿わせて将来 macOS/watchOS/visionOS に拡張可能に保つ
（今回は iOS のみ実装）。

### ③ crash 観測プロトコル
env epoch を凍結する（Simulator 1 台固定・再 install しない）。同一 cell を N 回 run し
crash/exit0 を記録する。**同一 cell が同一結果を返すこと（決定論性）自体を要件**とし、
結果が割れたら「まだ統制できていない入力がある」と判定して、その入力を特定し潰す
（env epoch 交絡の再発防止）。crash 時は signature（`remove_free_block ← est_free ←
mrb_basic_alloc_func ← mrb_close ← repl_eval`）の一致も確認する。

### ④ 履歴地形マップ（Phase 0 — 探索を計画に含める）
teardown 経路（bridge の `mrb_close`）/ `build_config` defines / `project.yml` defines /
`PICORUBY_REF` を触った commit を **scripted git 調査**で列挙し、候補 cell を導出する。
これは行き当たりばったりの探索ではなく、plan 内の定義された step として実行する。
既知の候補軸: `build_config/r2p2-picoruby-ios-repl-sim.rb` の cc.defines と
`examples/ios/repl/project.yml` の `GCC_PREPROCESSOR_DEFINITIONS` の不一致
（`MRB_USE_TASK_SCHEDULER=1` / `MRB_USE_VM_SWITCH_DISPATCH=1` /
`MRB_CONSTRAINED_BASELINE_PROFILE=1` / `MRB_HEAP_PAGE_SIZE=128` が app 側のみ）。
これが境界をまたぐ struct layout に効くなら ABI 不一致 → teardown 破綻の物理的正体たり得る。
ただし picoruby default が一部を補う可能性があるため、④ で事実確認してから軸に採る。

### ⑤ スイープ戦略（単一変数統制・承認済みアプローチ A）
commit 軸を scripted-build で **bisect**（各 commit を同一手順でビルドし example 動作を
確認した上で crash/no-crash を判定）。crash 境界 commit を絞ったら、その commit で
**param 軸**（特に libmruby.a と app の define 一貫性）を対照する。**変える変数は常に 1 つ**。
全格子総当たりではなく O(log n) で境界を絞る。

### ⑥ 真因確定 → 処置分岐
- **build-param 起因**（例: define 不一致による ABI 破綻）なら → build config を一貫化
  （defines の single source 化で `build_config` と `project.yml` がドリフトしない構造に）
  し、ワークアラウンド（`mrb_close` の無効化）を除去して、example が**実 teardown で**動く。
- **estalloc 内部起因**なら → 決定論的再現を添えて upstream（estalloc / mruby、victim か
  culprit かの決着次第）へ bug report を起草する（投稿は user 承認必須）。

## 5. モデル配分（横断制約・token 最適化）

実行時に subagent へ委譲する際のモデル指定:

- **決定論的コマンド実行**（ビルド run・git 操作・observation run・hash 採取）→ **haiku**
- **コード変更**（build config 一貫化・bridge 修正）→ **sonnet**
- **探索・計画**（履歴地形マップ・スイープ設計・真因推論・レビュー）→ **opus**

各委譲は目的・背景を添え、出力は必要最小限に絞って main context を汚さない。

## 6. systematic-debugging へのマッピング

- **Phase 1（root cause investigation・飛ばさない）** = ①ビルドセル基盤 + ②example ゲート
  + ③crash 観測プロトコル + ④履歴地形マップ
- **Phase 2（仮説検証）** = ⑤スイープ（commit bisect → 境界で param 軸対照）
- **Phase 3/4（修正・検証）** = ⑥処置 + 完了基準ゲート（実 example が実 teardown で動く）

## 7. 成果物

1. **公式ビルド・検証ターゲット**（既存 `Rakefile`/`build_config` を更新、commit して版管理）:
   cell 仕様 + content-hash 決定論検証 + example-works 自動判定。既存の `define_ios_example` /
   platform namespace の型に沿い、将来 macOS/watchOS/visionOS へ拡張可能な形。
2. 〈commit × param〉スイープの結果表（各セルの hash・example 動作・crash 有無）。
3. 真因の特定（crash 境界と、それを説明する単一変数）。
4. 処置（build config 一貫化 + WA 除去 で実 teardown 動作、または upstream bug report 草稿）。
