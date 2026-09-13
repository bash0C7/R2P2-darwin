# port-darwin rebase と R2P2-darwin 全example回帰 design

## 背景

`bash0C7/picoruby` の `port-darwin` branch(picoruby-ble等のdarwin port)は、`picoruby/picoruby` masterに対して ahead 36 / behind 36 で乖離していた。behind側の36コミットには `fix-ble-gc-root-leak`・`improve-ble-uart`(reconnect listener leak修正含む)という、StackchanPico.app(長時間稼働しBLE再接続を繰り返すdaemon)に直撃するfixが含まれている。「今動いている」は narrow smoke testが通っただけで、このgapがもたらすリスクの不在を証明しない。

並行して `R2P2-darwin` には未解決の `examples/ios/repl` crash調査(`HANDOFF.md`)がある。前回セッションの因果的結論(estalloc内部欠陥・R2P2-darwin無罪)はビルド入力・実行環境epochを制御しないまま導かれ、敵対的レビューで交絡と判明、reset済み。産出された調査資産(`/tmp/innocence/`一式、`bisect-*` worktree/Simulator、`docs/plans/2026-07-18-estalloc-*`)もその confound された手順の産物であり、保存する価値がない。

## 目的

rebaseによるupstream同期は**必要条件**。このセッションのミッションは**動くソフトウェアを作ること**(十分条件)。rebase自体をHANDOFF §6が要求する「単一変数の統制実験」として使い、必要条件と十分条件を同時に前進させる。

## スコープ

以下7フェーズすべて。良し悪しで間引かない — stackchan-picorubyの検証はR2P2-darwinの5 example全てが共有基盤(bridge/、build_config、vendor picoruby pin)を叩く別角度の検証であり、一部を割愛すれば残りで共有基盤のバグを見逃す。

1. クリーンアップ + 決定論的ビルド基盤の確立
2. 現状pin(`8bafbb2a`)でのbaseline確立
3. port-darwin rebase実行
4. rebase後の再ビルド・baseline比較
5. crash調査続行(まだ残る場合)
6. 全5 example回帰(emulator→iPhone/Apple Watch実機)
7. Mac app実機回帰 + stackchan-picoruby CLAUDE.md規律追加

### 明示的に含めないもの

- `picoruby/picoruby#427`への追加作業(既に別トラックで完了・push済み、review/merge待ちはuser判断)
- estalloc upstream bug報告の実際の投稿(調査が進んでも、投稿はuser承認必須)

## フェーズ詳細

### Phase 1: クリーンアップ + 決定論的ビルド基盤

- `git worktree remove --force` で `/private/tmp/bisect-work-95d70ee`・`-c27c1c3`・`-e1f1c5b` を除去
- `xcrun simctl delete` で `bisect-1〜4`(4台)を削除
- `/tmp/innocence/` 配下(harness・fuzzドライバ・watchpoint script・生トレース)を `rm -rf`
- `docs/plans/2026-07-18-estalloc-writesite-*` 等、HANDOFF自身が「交絡を踏まえ作り直し対象」と明言したconfounded docをcommitで削除
- 以降全ビルドは `rake` + `build_config/` のscript経由のみ。ad-hocな `clang` 手打ちでの `-I`/lib個別調整は禁止(HANDOFFで「言語道断」と明言済みの反復防止)

**完了基準**: `git worktree list` / `xcrun simctl list` / `ls /tmp/innocence` でいずれも対象が存在しないことを確認

### Phase 2: 現状pinでのbaseline確立

5 example(`repl`/`stackchan`/`virtual-peripheral`/`iphone-torch`/`led-toggle`)それぞれを対応する `build_config/r2p2-picoruby-ios-<example>-sim.rb`(watchOSは`-watchos-{sim}.rb`)でビルドし、**example毎に新規作成したSimulator**(使い回さない — env epoch汚染を避けるため)へinstall・起動。「crashせず起動維持」を最低ラインとして記録し、`repl`はcrash再現有無も記録する。Mac appも `r2p2-stackchan-pc.rb` でbuild+起動確認のみ(BLE実機smokeはPhase 7)。

**完了基準**: 6項目(5 example + Mac app)全てについて、ビルド成功可否・起動成功可否・(replのみ)crash再現可否を記録した表がある

### Phase 3: port-darwin rebase実行

`git rebase origin/master`(picoruby/picoruby)。

- rebaseで過去36コミットのSHAが書き換わるため `push --force` が必要(`port-darwin`は個人fork branchなので許容範囲、実行前に明示する)
- port-darwinはBLE darwin portを追加、upstream側はBLE GC leak fixを含む — **BLE関連ファイルでの衝突が高確率で発生する**。機械的な自動解決を前提にせず、衝突箇所は個別に読んで解決する

**完了基準**: `git status` で衝突ゼロ、`git log` がorigin/masterの上に線形に積まれている、origin へforce push済み

### Phase 4: rebase後の再ビルド・比較

Phase 2と同一手順で6項目を再確認。`R2P2-darwin` の `PICORUBY_REF`(現在`8bafbb2a`固定)をrebase後の新SHAへ更新するのもこのフェーズに含む。Phase 2の記録と突き合わせ、`repl` crashの有無変化を含め差分を明文化する — これがHANDOFF §6-5の統制実験そのもの。

**完了基準**: Phase 2/4の比較表が揃い、rebaseがcrash挙動に与えた影響(消えた/変わらず/悪化)が判定されている

### Phase 5: crash調査続行(まだ残る場合)

Phase 4でcrashが残っていた場合のみ実施。HANDOFF §6の手順(env epoch凍結 → crashするbinaryをhash付きで凍結 → build入力差分特定 → 単一変数統制実験 → commitの決定論的bisect)を踏襲。起点はPhase 4後のrebased状態。

**完了基準**: 決定論的に再現可能な最小構成が確立し、根本原因(victim/culprit)が特定される。ただし完全解決まで到達しない場合は、その時点までの堅い事実と次に取るべき手順を明文化して終える(未解決を「解決した」と偽らない)

### Phase 6: 全5 example回帰(emulator→実機)

example毎の最小機能smoke(`repl`: irb評価、`stackchan`: BLE往復、`virtual-peripheral`/`iphone-torch`: 該当機能動作、`led-toggle`: LED点灯)。emulatorで5本全PASSを確認してから、iPhone/Apple Watch実機(現在オフライン、接続はそのフェーズでuserに依頼)で同じsmokeを実施。

**完了基準**: emulator 5/5 PASS、実機 5/5 PASS(実機テストできないexampleがあれば理由を明記)

### Phase 7: Mac app実機回帰 + CLAUDE.md規律

このsessionで既に確立済みの手順(`ble_torque_smoke`/`ble_control_smoke`/`ble_servo_smoke`)を、rebase後のMac app binaryで再実行。全PASS確認後、stackchan-picoruby CLAUDE.mdへ「BLE系upstream fixは定期的にrebaseで取り込む」等の再発防止規律を追記・commit。

**完了基準**: 3種smoke全PASS、CLAUDE.md追記がcommit済み

## リスク

- Phase 3のBLE関連ファイル衝突は、機械的解決不可な実質的な設計判断を要する可能性がある
- Phase 5のcrash調査は、根本原因特定まで到達しないまま時間を使い切るリスクがある(honest reportingで対応、虚偽の解決宣言はしない)
- 実機(iPhone/Apple Watch)は現在オフラインで、接続タイミングはuser依存
