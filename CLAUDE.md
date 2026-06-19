## このリポジトリ

`R2P2-macOS` ＝ 標準 PicoRuby / R2P2 を macOS host で build/run する harness。依存する picoruby は
**GitHub upstream `picoruby/picoruby` を `rake setup` で `vendor/picoruby` に取得**する
（submodule 不使用・sibling fork 非依存）。ビルド出力は `MRUBY_BUILD_DIR=./build` に隔離し、
取得した picoruby source は pristine に保つ。harness なので port source は持たない。Mac ネイティブ能力は
upstream を汚さず `mrbgems/` として足す方針。BLE/CoreBluetooth port は picoruby tree 側に住み（upstream 提案中）、
本リポジトリは `rake build:ble` で build し `test/ble-darwin/` で検証する役割。

## 行動

- **足る情報が揃ったら即行動する**。会話で確立済みの事実の再導出、決定済み事項の再審議、採らない選択肢の説明をしない。選択に迷うなら推奨を 1 つ示す
- **タスクが要求する以上のことをしない**: 機能追加・refactor・抽象化・将来要件への設計・起こり得ない事象への error handling / fallback / validation を足さない。動く最も単純なものを書く。検証は system boundary（user 入力・外部 API）のみ
- **user 確認で止まるのは 3 条件のみ**: 破壊的/不可逆な操作・実質的な scope 変更・user にしか提供できない入力。turn の末尾が計画・質問・未実行の約束なら、いま tool call で実行してから終える
- user が問題の記述・質問・思考の言語化をしている時の成果物は assessment。**修正は依頼されてから**

## 報告

- **進捗・完了の主張は当 session の tool result で裏付けてから報告する**。未検証は未検証と明言。test 失敗は出力ごと報告。skip した step は skip と言う
- **outcome を先頭に**: 最初の 1 文が「何が起きたか / 何が見つかったか」
- **最終 message は作業を見ていない読者への re-grounding** として書く

## memory

- 1 知見 1 ファイル、先頭に 1 行 summary。修正指摘も確認済みアプローチも理由とともに記録。repo や履歴が既に記録するものは保存しない。重複を作らず既存を更新し、誤りと判明したら削除
