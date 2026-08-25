# R2P2-darwin

PicoRuby を Apple プラットフォーム（macOS host / iOS / watchOS）へ載せるハーネス。
設計・タスク一覧・環境変数・example の説明は [README.md](README.md) が単一の
source of truth。**このファイルには README に書いていないことだけを置く。**

## 触ってよい場所

| 対象 | 置き場所 |
|---|---|
| build_config / bridge / example アプリ / example 専用 gem | 本 repo |
| gem の `ports/darwin/`、`darwin?` 述語、port loader | fork `bash0C7/picoruby` の `port-darwin` |

- `vendor/picoruby` は生成物。**commit しない。** 本 repo から upstream への push / PR もしない
- fork の編集は clone `~/dev/src/github.com/bash0C7/picoruby` で `port-darwin` の worktree を切って行い、
  `port-darwin` へ直接 commit する（topic branch を作らない）。push は user 承認
- 未 push の fork commit を検証に流し込む:

  ```bash
  PICORUBY_REPO=/Users/bash/dev/src/github.com/bash0C7/picoruby PICORUBY_REF=port-darwin rake refresh
  ```

- `port-darwin` は upstream master に対して behind 0 を保つ。upstream の変更で build が壊れたら、
  古い SHA に pin して逃げず、本 repo（build_config / bridge / project.yml）と fork の port を
  upstream に合わせて直す。影響範囲の大きさは回避の理由にならない
- fork 側で darwin port を複数 branch に分けたら、push 前に `PICORUBY_REF` が指す branch へ統合する

## 壊しやすい不変条件

- **`picoruby-ble` の `picoruby-mbedtls` / `picoruby-rng` 依存を外さない。** `ble.rb` は boot で
  `require 'mbedtls'` し、GATT database hash が `MbedTLS::CMAC` を使う。外すと BLE の Ruby 層が
  丸ごと未ロードになり `BLE.new` が `wrong number of arguments` で落ちる
- **example 固有の gem は example 専用 build_config に置く。** 共有 base に足すと、その gem を使わない
  example の app link が未解決シンボルで壊れる
- **`ports/darwin/` は自己完結。** CrossBuild は first match で darwin だけを compile するので、
  posix port が提供する symbol を全部自前で持つ
- **mruby task HAL の 6 entry（`mrb_hal_task_init` / `_final` / `_idle_cpu` / `_sleep_us`、
  `mrb_task_enable_irq` / `_disable_irq`）は `bridge/task_hal_ios.c` の所有物。**
  darwin port の `hal.c` に定義しない — archive 内の posix `task_hal.o` が引かれて二重定義になる。
  upstream が entry を足したら bridge にも足す
- **define parity。** `examples/*/*/project.yml` の `GCC_PREPROCESSOR_DEFINITIONS`、build_config、
  `Rakefile` の smoke defines を一致させる。`sizeof(mrb_state)` に効く不一致は bridge と lib の間の
  メモリ破壊になる。`MRB_BASELINE_PROFILE=1` は config に書かれず `picoruby-mruby` が build-wide に
  足すので、手書きの側が追従する。確認は `cd vendor/picoruby && rake -v` の compile command から
  `-D` を抽出して突合
- `picoruby-mruby/mrbgem.rake` を変えたら `build_config/recompile_arm64_32.rb` も追従する
- gem の `ports/darwin/ext/` は Swift package。darwin port に C source を足すときは `ext/` の外へ置く
- build_config の define を変えたら再 build 前に `rm -rf build/<target>` — compile rule は `.c` の
  mtime しか見ないので stale `.o` が再利用され、変更が黙って効かない

## 完了の線引き

`rake smoke`（host、CI が回す）→ `rake ios:<name>:device:check`（署名不要）→
`rake ios:<name>:observe`（挙動）。実機の挙動は実機で実証するまで「動いた」と書かない。
実機・実 service が使えないなら、その旨を 1 行報告して完了宣言を保留する。

device 系 rake を tmux / subagent から回すときは command 側で `LANG` と `RBENV_VERSION` を明示する。
端末名に非 ASCII があると `devicectl` / `xcodebuild -showdestinations` の出力に対する Rakefile の
regex が `invalid byte sequence` で落ちる。

## Session の役割分担

build / clone / 署名の log は長い。main context に流し込むと判断の質が落ちるので分離する。

- **haiku subagent**: 決定論的なコマンド実行（build、install、`rake refresh`、tmux の長尺 job、
  script による書換え、git plumbing）。実行するコマンドを verbatim で渡し、raw output をそのまま
  返させる。解釈・要約・改変をさせない
- **sonnet subagent**: log と証拠の解釈（build log / link error / test 出力 / `git log`）。
  事実と推論を分けて報告させ、推奨は求めない
- **main**: 何を実行するかの決定、report の吟味（「成功」を鵜呑みにせず tool 結果と突合）、
  scope と plan の管理、user との対話。自分で長い log を読まない

進捗報告は必ず tool 結果に紐づける。未検証は未検証と書く。失敗は出力付きでそのまま報告する。
