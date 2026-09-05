# R2P2-darwin 磨き上げ — iOSDC 2026 トークベース整備 設計

日付: 2026-07-17
背景: iOSDC Japan 2026 採択トーク「マイコン向けの軽量Ruby「PicoRuby」でAppleデバイスを制御するネイティブアプリの実現手法」のベース成果物として、R2P2-darwin を picoruby/R2P2-ESP32 をお手本に磨き上げる。方針は「シンプルに」— 機能の水増しではなく、聴衆が clone して再現できる品質・repo 標準物・ドキュメント導線の整備。

決定事項(user 承認済み):
- 実施範囲: P1 + P2 全部
- docs/ 直下の完了済み handoff / plan 4 本は git rm(履歴に残る)。docs/superpowers/ は慣習どおり維持
- default task は `rake ios` と同じ(お手本 ESP32 の `default => all` と同型)

制約: vendor/picoruby と upstream fork には一切変更を入れない。EN/JP README は同一 commit で更新する。

## P1 — 必須

1. **LICENSE 追加**: MIT(Copyright (c) 2026 bash0C7)を root に。README.md / README_jp.md 末尾に License / ライセンス節。
2. **Getting Started 新設**: README 冒頭(What this is の前)に番号付き最短導線 — (1) git clone (2) フル Xcode.app 前提 + brew install xcodegen (3) rake check (4) rake ios(署名不要・Simulator で repl 起動、vendor fetch は task 依存で自動)。初回 fetch ~1.2GB / build 込み ~3GB の目安を明記。Setup 節末尾に rake setup と次の一手への接続を追記。
3. **DEVELOPMENT_TEAM placeholder 化**: 全 7 project.yml の実 Team ID を YOUR_TEAM_ID に置換。README の On-device builds 節と各 example README の device 手順に書き換え方(Xcode > Settings > Accounts、必要なら bundleIdPrefix も)を追記。Simulator 経路が壊れないことを xcodegen + sim build で検証してから確定。
4. **EXAMPLE 環境変数の廃止**: repl を IOS_EXAMPLES(define_ios_example)に統合して ios:repl:* を生成。base の ios:{lib,gen,build,run,all} は alias として維持。EXAMPLE / APP_DIR / VENDOR_DIR を削除し、README の EXAMPLE 記述も削除。誤用(EXAMPLE=stackchan rake ios が他 example の Vendor を破壊)の経路自体を消す。
5. **docs 整理**: docs/2026-06-27-networking-handoff.md と docs/plans/ 3 本を git rm。
6. **default task**: `task default: :ios` を追加。

## P2 — やると良い

7. **最小 CI**: .github/workflows/ci.yml — macos-15 runner、push/PR to main、steps = checkout → setup-ruby → brew install xcodegen → cache(vendor/picoruby を ls-remote sha キーで、build/ も)→ rake smoke → rake ios:lib ios:gen ios:build(明示順; ios:build は gen に依存宣言が無い)。device/署名/:run 系は除外。.github/dependabot.yml は github-actions ecosystem のみ(weekly)。
8. **rake check 堅牢化**: 全項目を検査し切ってから失敗があればまとめて abort(xcodegen の warn 止まりを解消)。成功末尾に next: rake ios を案内。desc に macos:check への相互参照。
9. **Verified Environment 表**: 両 README に確認済み環境(Xcode 26.5 / macOS 26.5 / Ruby 4.0.5、target 別の確認状況)。
10. **root README スリム化**: Examples 節を「1-2 行 + rake コマンド + example README リンク」定型に統一(~200 行目標)。task 名 ↔ ディレクトリ対応表を吸収。Vendor fork 節は要約 + リンクに縮約。
11. **example README テンプレート統一**: 概要 → How it works → Dependencies(該当時)→ Build & run(Simulator / Device)→ Individual rake tasks → Known constraints(該当時)。7 example × EN/JP。
12. **env 変数の発見性**: 関係 task の desc に IOS_MIN / WATCHOS_MIN / PICORUBY_REPO / PICORUBY_REF を付記。README の env 表に WATCHOS_MIN / PICORUBY_BLE_GEMDIR を追記。
13. **rake clean 全 Vendor 対応**: examples/*/*/Vendor を glob で rm_rf(EXAMPLE 廃止と同時に整合)。
14. **標準物**: .ruby-version(4.0.5)、.gitignore に .DS_Store。
15. **example 自己説明性**: examples/macos/ls に README ペア追加、examples/watchos/led-toggle/app.rb に冒頭コメント。

## 採用しない(cut)

release workflow(prebuilt libmruby.a は中間物で配布価値が薄い — 手動 tag で足りる)/ web installer 相当(Apple の署名モデル上不成立 — 等価物は Simulator 経路)/ dependabot gitsubmodule(vendor は submodule でない)/ rake -T 削減(desc は資産)/ example ディレクトリのリネーム(波及過大 — 対応表で解決)/ check 統合(前提が異なる)/ Team ID の env 展開機構・shallow clone・EN/JP 同期自動化・rake ci aggregate(いずれも過剰機構)。

## 検証

- Rakefile 変更後: `rake -T` / `rake smoke` / `rake ios:gen ios:build`(staged Vendor 再利用)
- project.yml 変更後: placeholder 状態で Simulator build が通ること
- README 変更後: EN/JP の節構成一致を突き合わせ
- CI は push しないと実走できないため、YAML 構文検証まで(push は user 判断)
