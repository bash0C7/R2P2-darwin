# R2P2-darwin 無罪証明プロトコル — 設計（spec）

## 目的

iOS Simulator 上の `examples/ios/repl` crash（estalloc ヒープ破損、100% 再現）について、
「R2P2-darwin 側の変更は crash の必要原因ではなく、欠陥は vendor（picoruby）コード内に
単独で存在する」ことを仮説検定の形式で証明または反証する。証明が成立した場合のみ、
vendor 側の課題として picoruby 本体への issue を起草する（投稿は user 承認必須）。

## 前提となる確立済み事実

- crash は `mrb_close` teardown 中の `est_free`/`remove_free_block` で EXC_BAD_ACCESS。
  ContentView の初期入力 `puts "hello #{1 + 2}"` を `.onAppear` の `repl_eval` が
  評価するだけで 100% 再現する。
- git bisect（実 Simulator 起動 + crash log による検証）で、regression 導入 commit は
  `0548b9e`（build_config を最小 gembox からフル POSIX gembox へ切り替えた設定変更）と確定。
  `bridge/picoruby_bridge.c` は動いていた時代から crash する現在まで diff ゼロ。
- lldb watchpoint 追跡により、破損は gem init 経路（ENV hash 構築 → io-console
  メソッドテーブル拡張 → `mrb_env_unshare` → hash-ext ROM メソッドテーブル初期化 →
  `mrb_close` 中の GC free）で仕込まれる。
- vendor 純正 `picoruby` バイナリ（`mrbgems/picoruby-bin-picoruby/tools/picoruby/picoruby.c`
  の `cleanup()`）は `mrb_close` を `// TODO: fix segv` とコメントアウトして回避している。
- app 側 `MRB_CONSTRAINED_BASELINE_PROFILE` と lib 側 `MRB_BASELINE_PROFILE` の define
  不一致という R2P2-darwin 側の実欠陥が現存する（crash への因果は否定的だが推論止まり。
  未清算の交絡因子として扱う）。

## 仮説の定義

### 帰無仮説 H0「R2P2-darwin は有罪」（2 分解、既定で棄却されていない側）

- **H0-a（必要原因性）**: 動いていた commit（`0548b9e` の親）以降に R2P2-darwin 側へ
  加えられた変更（bridge / build_config / project.yml / example コード）のうち少なくとも
  1 つは crash の必要原因である。すなわち R2P2-darwin 側を修正しない限り crash は解消しえない。
- **H0-b（契約違反）**: R2P2-darwin による vendor API の利用 — bridge の VM ライフサイクル
  （eval 毎の `mrb_open_with_custom_alloc` → 実行 → `mrb_close`）および build_config で
  選択した define・gembox・port の組み合わせ — は vendor が保証する契約の外にあり、
  crash はその契約外利用が引き起こしている。

### 対立仮説 H1「無罪」

¬H0-a かつ ¬H0-b。crash の必要十分な欠陥は vendor コード内に単独で存在する。

### 棄却判定

- **H0-a 棄却条件**: 欠陥を行レベルで特定した上で、vendor のみに最小パッチを当て、
  R2P2-darwin HEAD を 1 文字も変更せずにリビルドし、100% 再現手順を Simulator で
  10 回連続実行して crash 0 回。crash が 1 回でも残れば棄却失敗（= R2P2-darwin 側に
  必要原因が残る）。
- **H0-b 棄却条件**: bridge が呼ぶ各 vendor API が公開契約（ヘッダ・upstream mruby の
  意味論・vendor 自身の利用例）の範囲内であることを監査で示す。契約外利用が crash の
  必要条件と判明すれば棄却失敗（= 少なくとも共同責任）。
- **反証可能性**: 行レベル特定の過程で破損の起点が R2P2-darwin 側コード（bridge の
  heap 寿命管理・fd リダイレクト・define 不一致等）と判明した場合、その時点で H0-a を
  確証とし、無罪証明は失敗として終了・報告する。

## 証明が「以降の全 commit」を一括カバーする理由

反実仮想テストは無変更の HEAD に対して行う。HEAD が vendor 修正のみで動くなら、
動いていた commit から HEAD までのどの R2P2-darwin 側変更も「修正を要しない」
＝どれも必要原因ではない、が一括で示される。

## 完了基準（全 step 共通・user 指定）

各 step の完了判定は **iOS Simulator 上での実行**で行う。判定は「non-crash かつ想定
どおりの動作」を**動作（実行結果・プロセス生存）とログ（stdout/stderr・crash report
の不在）の両方**で確認して初めて成立する。macOS host 上の実験は差分因子の切り分け
情報としてのみ扱い、host 単独の観測を step 完了の根拠にしない。診断目的の step
（ベースライン確認等）は「期待される観測（例: crash の発生）がログと動作の両方で
確認できたこと」を完了条件とする。

## プロトコル（Phase A–E）

| Phase | 内容 | 判定ゲート |
|---|---|---|
| A | macOS host（native デバッグ環境）で `bridge/picoruby_bridge.c` **そのもの**を最小 main とともに host libmruby.a にリンクし、iOS と同一ライフサイクルを実行。crash したら `ESTALLOC_DEBUG` リビルド + lldb で欠陥を行レベル特定 | 行特定できるまで B 以降に進まない。起点が bridge 側なら H0-a 確証で終了 |
| B | 特定した欠陥行が iOS crash と同一経路であることを計測で同定（シグネチャ類似での断定を禁止） | 同定不成立なら A に戻る |
| C | bridge の vendor API 利用の契約監査（H0-b）。`mrb_close` の「TODO: fix segv」問題を含む | 契約外利用が必要条件なら H0-b 棄却失敗で終了・報告 |
| D | vendor のみの最小パッチ（working tree のみ、commit 禁止）→ 無変更 HEAD の iOS app を再ビルド → Simulator 10 回連続起動 | crash 0/10 で H0-a 棄却。1 回でも crash で棄却失敗 |
| E | 無罪確定後のみ: upstream `picoruby/picoruby` に同一欠陥が存在するか確認（fork 由来切り分け）し、issue 起草 | issue 投稿は user 承認必須 |

Phase A で host 再現しない場合のフォールバック: iOS Simulator 上で `ESTALLOC_DEBUG`
build + lldb により行特定する（A の目的は達成手段が変わるだけで、ゲートは同一）。

## 実行体制

- 制御・ゲート判定・証拠の採否: Fable（main loop）。
- 実行フェーズの各 task（ビルド・ハーネス実行・lldb 計測・ログ収集）: Sonnet subagent
  （Agent tool, `model: "sonnet"`）に委譲。subagent には判定をさせず、観測事実のみを
  返させる。

## 制約（非交渉）

- `vendor/picoruby` への commit は絶対禁止。Phase D のパッチは working tree のみで、
  検証後 `git -C vendor/picoruby checkout -- .` で復元する。
- upstream fork（`bash0C7/picoruby`）への push / branch 作成 / PR / issue 投稿は
  user 確認必須。
- 恒久修正・merge の話題は本プロトコルの scope 外（実機確認は user のみが完了を宣言できる）。
- 各 Phase の棄却失敗（= 有罪方向の確証）が出た時点で停止し、user に報告する。

## 成果物

1. 判定結果（H0-a / H0-b それぞれの棄却成否と証拠）
2. 欠陥の行レベル特定情報（ファイル・行・破損メカニズム）
3. 無罪確定時: picoruby 本体向け issue 草稿（root cause・最小再現・パッチ案）
