# estalloc 破損の書き込み元特定・ワークアラウンド・bug report — 設計（spec）

## 目的

`examples/ios/repl` の iOS Simulator crash（`mrb_close` teardown 中の estalloc
`est_free`/`remove_free_block` で `EXC_BAD_ACCESS`、100% 再現）について、既に確立
済みの「R2P2-darwin 無罪・欠陥は vendor 側 estalloc」という結論を踏まえ、次の 3 つの
成果物を得る。

1. **破損の書き込み元特定** — crash 地点から後ろ向きに、`est_free` が読み出す値
   `0x12` の出所を辿り、根本原因を行レベルで言語化する。
2. **ワークアラウンド** — R2P2-darwin 側のみで crash を解消する変更を実装し、実
   Simulator で検証する。
3. **再現コード付き bug report** — 環境非依存の決定論的再現を作り、正しい upstream
   リポジトリ宛の issue を起草する（投稿は user 承認必須）。

## 前提となる確立済み事実（HANDOFF より）

- crash: `remove_free_block ← est_free ← mrb_basic_alloc_func ← mrb_close ← repl_eval`。
  crash 命令は `remove_free_block` の `ldr x8, [x1, #0x10]`、`x1 = 0x12`、crash address
  `0x22 = 0x12 + 0x10`。`est_free` の「前ブロックと合体するか」判定で、`target-8`
  （直前ブロックの footer 位置）から読んだ back-pointer が `0x12` になっている。
- 安価な再現系が確立済み（Xcode 不要）: host libmruby.a + `bridge/picoruby_bridge.c`
  を clang でビルドした `/tmp/innocence/harness` を、sandbox 由来の 4 環境変数
  （`SIMULATOR_VERSION_INFO`/`CFFIXED_USER_HOME`/`HOME`/`TMPDIR`）付きで
  `xcrun simctl spawn` 経由実行すると同一 crash が 100% 再現する（HANDOFF §2）。
  直接シェル exec では再現しない。
- lldb attach + `-k`（one-line-on-crash）で crash 瞬間の backtrace/レジスタ/メモリを
  採取できる（HANDOFF §2.3）。`ESTALLOC_DEBUG` はメモリレイアウトを変えて crash を
  消す heisenbug 特性があるため診断に使えない（HANDOFF §2.4）。
- `est_free` の prev 合体パス（`estalloc.c` ~795-805 行）は、next 合体パスと違い
  境界 sanity チェックを持たず、`IS_PREV_FREE(target)`（`target->size` 下位ビット）を
  信じて footer の back-pointer を無条件 dereference する。
- vendor 純正 `picoruby` ツール（`tools/picoruby/picoruby.c` の `cleanup()`）は同じ
  segv を踏んで `mrb_close` を `// TODO: fix segv` でコメントアウト回避している。
- estalloc は独立 repo `github.com/picoruby/estalloc` の submodule。vendored HEAD
  `971b793`、working tree clean（fork 改変ゼロ・upstream 完全一致）。`test/test.c` +
  `make test` + CI という決定論的テストの受け皿を持つ。

## ① 破損の書き込み元特定

### 方針

crash 地点から `0x12` の出所を **1 本、後ろ向きに辿る**（backward data-flow tracing）。
観測と追跡を分けず、crash 地点から書き込み元（または欠陥箇所）まで連続して辿る 1 つの
作業とする。辿る前にどの結末（footer への write／`size` フラグへの write／どこも上書き
していない純ロジック欠陥）に着地するかを賭けない。**A/B（footer 上書きか est_free 誤読か）の
判別を先行ゲートにしない** — どちらかを先に決めてから枝分かれするのではなく、`0x12` を
保持する番地を追い、その結果として破損の性質が判明する。

### 手順

- **crash 時状態の観測（追跡への入力採取）**: 安価な再現系 + lldb で crash 停止時に、
  `est_free` フレームの `target` 値・`target->size`（PREV_FREE ビット）・`target-8` の
  内容・`BPOOL_TOP` からの pool 整合性ウォーク・crash ブロックの `BPOOL_TOP` 相対
  オフセットを読む。ここで **`0x12` を保持している番地**（footer の `target-8` か
  `target->size` か）を特定する。これを独立に複数回実行し相対オフセット等の**決定性**を
  確認する（watchpoint 前提）。この観測は A/B の判別を目的とせず、追跡対象の番地を採る
  ためのもの。
- **書き込み元の追跡**: `0x12` を保持する番地（前段で特定）を ASLR 対策として `BPOOL_TOP`
  相対オフセットで扱い、`est_init` 直後に write watchpoint を張って run 全体の write を
  記録し、crash 直前に `0x12` を書いた最後の命令を書き込み元とする。整合性が一貫していて
  write が見つからない（＝どこも上書きしておらず estalloc 自身の境界・サイズ計算が
  `target-8` を誤って footer 扱いしている）場合は、その計算欠陥箇所を辿りの終点とする。
  footer 上書きか・フラグ上書きか・純ロジック欠陥かは、辿った**結果の性質づけ**であって
  着手前に決める分岐条件ではない。
- **根本原因の言語化**: 「誰が書いたか」の生アドレスに留めず、「estalloc（または caller）の
  どの不変条件が、どの条件下で破れるか」を 1 文で述べる形にまとめる。これが③の宛先
  リポジトリと issue 本文の root-cause 節を規定する。

### 診断手段の段階

1. まず lldb の read-only 観測のみ（vendor ソース非改変）で crash 時状態と watchpoint
   追跡を試みる。
2. lldb 単独で書き込み元を確定できない場合、`est_free`/`add_free_block` 冒頭から呼ぶ
   **read-only の pool 整合性チェッカ**を vendor working tree に一時挿入する（struct は
   非改変、`-O0` 維持、内部 alloc を踏まないよう `write(2)` + 固定バッファのみ使用）。
   「最初に整合性が壊れる free の通し番号」と当該ブロックのダンプを採る。この挿入は
   working tree のみ・検証後に必ず `git checkout` で復元し、**commit しない**（Phase D の
   vendor パッチと同じ扱い）。`ESTALLOC_DEBUG` は使わない。

## ② ワークアラウンド（R2P2-darwin 側のみ、①に非依存）

### 変更内容

`bridge/picoruby_bridge.c` の成功経路 `mrb_close` 呼び出しを除去する。根拠:
`repl_eval` は eval 毎に `calloc`（L90）で専用 heap を確保し末尾で `free(heap)`（L113）、
`vm_close` も `free(h->heap)`（L209）で arena 全体を解放しているため、`mrb_close`
（L110 / L207）は heap 回収の観点で冗長であり、OS レベルのリークを生まない。vendor
純正 `picoruby` ツールが `cleanup()` で行っている回避と同型。対象は crash 経路の
成功パス（`repl_eval:110`・`vm_close:207`）。error パスの `mrb_close`（`vm_open` 内
L141/L154/L163）も同様に直後 `free(heap)` があり冗長だが、crash 経路ではないため
一貫性の観点でのみ扱う。

### 完了基準（実 Simulator 検証必須）

実 Xcode app を実 Simulator にビルド・install・起動し、**動作（プロセス生存）とログ
（stdout/stderr・crash report の不在）の両方**で以下を確認して初めて完了とする:

- 起動時 `puts "hello #{1 + 2}"` が non-crash かつ想定出力（`hello 3`）。
- **2 回目以降の eval** が動作する（estalloc の file-scope static `est` が新 heap で
  正しく再初期化されるか。teardown を変える以上あらためて確認が要る）。
- **GC 誘発スクリプト**（alloc 多めで runtime GC を走らせる）が non-crash。`est_free` は
  teardown だけでなく runtime GC でも走るため、workaround 後に同じ footer を踏まないことを
  別途確認する。

## ③ 再現コード付き bug report

- **決定論的・環境非依存の再現**: `simctl spawn` / 長い環境変数への依存を「潜在バグを
  露出させる trigger の一例」に格下げし、estalloc standalone（`test/test.c` + `make test`
  の受け皿）で SIGSEGV を再現する縮約ケースを作る。①の結論（footer 上書き経路 or
  誤読経路）に沿って、`est_malloc`/`est_free` のシーケンス、または当該不変条件を人工的に
  破る最小ケースを構成する。
- **宛先リポジトリの確定**: ①の結論で分岐 — 欠陥が estalloc 内部（境界計算・フラグ管理）
  なら `picoruby/estalloc`、estalloc 外部からの out-of-bounds write なら mruby/picoruby。
  併せて estalloc upstream の commit log を確認し、`971b793` 以降に同一欠陥の修正が
  無いか調べる。
- **issue 草稿**: 症状 + crash backtrace + ①の root-cause（破れる不変条件）+ 決定論的
  再現手順 + 修正案。修正案は Phase D の境界チェックガードを含めるが、「本来合体すべき
  正当ケースを誤って skip しない保証は未検証」である旨を明記する（症状抑制と根本修正を
  区別する）。
- **投稿は user 承認必須**（外向きの不可逆操作）。

## 成果物間の依存関係

- ①→③: 宛先リポジトリと root-cause 節が①の結論に依存する。③の再現縮約も①に連動。
- ②は①に非依存で並行可能。
- 順序は ②（確実に価値を出す・de-risk）と①（crash 時状態観測）を先行させ、①の watchpoint
  追跡 → ③の再現縮約・宛先確定・草稿、と進める。

## 実行体制

- 制御・ゲート判定・証拠の採否: main loop。
- 実行フェーズの各 task（ビルド・ハーネス実行・lldb 計測・ログ収集）: Sonnet subagent
  （Agent tool, `model: "sonnet"`）に委譲。subagent には判定をさせず観測事実のみ返させる。

## 制約（非交渉）

- `vendor/picoruby` および estalloc submodule への commit は絶対禁止。①の診断挿入・
  ③の修正案検証は working tree のみで行い、検証後 `git checkout` で復元する。
- push / branch 作成 / PR / issue 投稿は user 確認必須。
- ②の merge の話題は本 scope 外（実機確認完了は user のみが宣言できる）。実装・
  Simulator 検証までを行い、merge は提案しない。
- `ESTALLOC_DEBUG` は heisenbug を消すため診断に使わない。
