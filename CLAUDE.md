# R2P2-darwin

PicoRubyをAppleプラットフォーム（macOS host / iOS / watchOS）へ載せるハーネス。
設計・タスク一覧・環境変数・exampleの説明は [README.md](README.md) が単一の
source of truth。**このファイルにはREADMEに書いていないことだけを置く。**

## 触ってよい場所

| 対象 | 置き場所 |
|---|---|
| build_config / bridge / exampleアプリ / example専用gem | 本repo |
| gemの `ports/darwin/`、`darwin?` 述語、port loader | fork `bash0C7/picoruby` の `port-darwin` |

- `vendor/picoruby` は生成物。**commitしない。** 本repoからupstreamへのpush / PRもしない
- forkの編集はclone `~/dev/src/github.com/bash0C7/picoruby` で `port-darwin` のworktreeを切って行い、
  `port-darwin` へ直接commitする（topic branchを作らない）。pushはuser承認
- 未pushのfork commitを検証に流し込む:

  ```bash
  PICORUBY_REPO=/Users/bash/dev/src/github.com/bash0C7/picoruby PICORUBY_REF=port-darwin rake refresh
  ```

- `port-darwin` はupstream masterに対してbehind 0を保つ。upstreamの変更でbuildが壊れたら、
  古いSHAにpinして逃げず、本repo（build_config / bridge / project.yml）とforkのportを
  upstreamに合わせて直す。影響範囲の大きさは回避の理由にならない
- fork側でdarwin portを複数branchに分けたら、push前に `PICORUBY_REF` が指すbranchへ統合する

## 壊しやすい不変条件

- **`picoruby-ble` の `picoruby-mbedtls` / `picoruby-rng` 依存を外さない。** `ble.rb` はbootで
  `require 'mbedtls'` し、GATT database hashが `MbedTLS::CMAC` を使う。外すとBLEのRuby層が
  丸ごと未ロードになり `BLE.new` が `wrong number of arguments` で落ちる
- **example固有のgemはexample専用build_configに置く。** 共有baseに足すと、そのgemを使わない
  exampleのapp linkが未解決シンボルで壊れる
- **`ports/darwin/` は自己完結。** CrossBuildはfirst matchでdarwinだけをcompileするので、
  posix portが提供するsymbolを全部自前で持つ
- **mruby task HALの6 entry（`mrb_hal_task_init` / `_final` / `_idle_cpu` / `_sleep_us`、
  `mrb_task_enable_irq` / `_disable_irq`）は `bridge/task_hal_ios.c` の所有物。**
  darwin portの `hal.c` に定義しない — archive内のposix `task_hal.o` が引かれて二重定義になる。
  upstreamがentryを足したらbridgeにも足す
- **define parity。** `examples/*/*/project.yml` の `GCC_PREPROCESSOR_DEFINITIONS`、build_config、
  `Rakefile` のsmoke definesを一致させる。`sizeof(mrb_state)` に効く不一致はbridgeとlibの間の
  メモリ破壊になる。`MRB_BASELINE_PROFILE=1` はconfigに書かれず `picoruby-mruby` がbuild-wideに
  足すので、手書きの側が追従する。確認は `cd vendor/picoruby && rake -v` のcompile commandから
  `-D` を抽出して突合
- `picoruby-mruby/mrbgem.rake` を変えたら `build_config/recompile_arm64_32.rb` も追従する
- gemの `ports/darwin/ext/` はSwift package。darwin portにC sourceを足すときは `ext/` の外へ置く
- **`build/<target>/` のstale化は `stage_libmruby` のstampが防ぐ。** compile ruleは `.c` の
  mtimeしか見ないので、build_configを変えても `rake refresh` でvendor/picorubyを入れ替えても、
  既存 `.o` が新しいsourceより新しければ何も再compileされず、lib taskは成功したと言いながら
  前のarchiveをstageする。`stage_libmruby` は `build/<target>/.r2p2-build-stamp` に
  「picorubyのSHA + build_configのdigest」を記録し、一致しなければdirごと捨てて再buildする。
  stampを回避してbuildするpath（`recompile_arm64_32.rb` の直接起動など）を足すときは、
  stampの更新も一緒に足す
- **各exampleのSimulator用とdevice用のlibmruby.aは同じ `Vendor/lib/libmruby.a` を共有する。**
  `lib` taskと `device:lib` taskは同じpathへ上書きし合い、guardが無い。`ld` はarch違いの
  static archiveをerrorにせず黙ってskipするので、片方のarchが刺さったままでも
  `** BUILD SUCCEEDED **` が出て、appは起動時に `-undefined dynamic_lookup` の
  Swift package側の未定義symbol（`_global_mrb` 等）でdyld crashする。`device:lib` の後に
  Simulator buildをする前（逆も同様）は必ずそのexampleの `lib` taskを再実行する。
  確認は `lipo -info examples/<platform>/<name>/Vendor/lib/libmruby.a`

## 完了の線引き

`rake regress:unit`（host、PRごとにCIが回す）→ `rake ios:<name>:device:check`（署名不要）→
`rake ios:<name>:observe`（挙動）。実機の挙動は実機で実証するまで「動いた」と書かない。
実機・実serviceが使えないなら、その旨を1行報告して完了宣言を保留する。

全exampleの横断確認は `rake regress`（unit → 全example device link → 全example Simulator build）。
step単位のlogは `build/regress/` に残り、失敗しても最後まで走ってからまとめて落ちる。
1 exampleだけなら `EXAMPLE=ios:torch rake regress:one`。CIでは
`.github/workflows/regression.yml` が同じ `regress:one` をexampleごとに並列で回す（週次 + 手動）。
matrixは `rake regress:examples` から作るので、exampleを足してもworkflowの編集は要らない。

device系rakeをtmux / subagentから回すときはcommand側で `LANG` と `RBENV_VERSION` を明示する。
端末名に非ASCIIがあると `devicectl` / `xcodebuild -showdestinations` の出力に対するRakefileの
regexが `invalid byte sequence` で落ちる。

## Sessionの役割分担

build / clone / 署名のlogは長い。main contextに流し込むと判断の質が落ちるので分離する。

- **haiku subagent**: 決定論的なコマンド実行（build、install、`rake refresh`、tmuxの長尺job、
  scriptによる書換え、git plumbing）。実行するコマンドをverbatimで渡し、raw outputをそのまま
  返させる。解釈・要約・改変をさせない
- **sonnet subagent**: logと証拠の解釈（build log / link error / test出力 / `git log`）。
  事実と推論を分けて報告させ、推奨は求めない
- **main**: 何を実行するかの決定、reportの吟味（「成功」を鵜呑みにせずtool結果と突合）、
  scopeとplanの管理、userとの対話。自分で長いlogを読まない

進捗報告は必ずtool結果に紐づける。未検証は未検証と書く。失敗は出力付きでそのまま報告する。
