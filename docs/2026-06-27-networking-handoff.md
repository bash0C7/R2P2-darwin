# HANDOFF — networking example / issue #6

状態: **進行中**（root-cause 解決済み、commit/検証は残）。worktree `.claude/worktrees/ios-posix-model`（branch `feat/ios-posix-model`）。次セッションでここから再開。

## 1 行サマリ
picoruby-net posix port の allocator-mismatch crash を root cause 特定して修正、Simulator で HTTP/HTTPS 成功を確認済み。残りは「修正の push」「R2P2-iOS 側の local commit」「実機検証」。

## 解決済み（当セッションで検証）
- **root cause**: picoruby-net の posix port（`mrbgems/picoruby-net/ports/posix/{tcp,tls,udp}_client.c`）が recv buffer を system `malloc/realloc/free` で確保し `res->recv_data` に格納。一方 `src/mruby/net.c` は `res->recv_data` を `mrb_free` で解放。default allocator では `mrb_free==free` で無害だが、iOS は `mrb_open_with_custom_alloc` の 8MB estalloc pool（`bridge/picoruby_bridge.c`）なので system-heap ポインタを estalloc free-list に投入 → `est_free`/`remove_free_block` で SIGSEGV。「hang」に見えたのは bridge が vm_call return 時のみ stdout を flush するため（crash で return せず無音）。
- **修正**: 上記 3 file の確保/解放を `picorb_alloc/realloc/free` に統一（= `mrb_*`、net.c の free と一致）。default allocator では no-op、custom allocator で正しさ回復。**全 posix consumer に効くソースレベル修正で iOS 固有ではない**（upstream 行き候補）。
- **検証**: Simulator で HTTP(1.1.1.1:80→301) と HTTPS(example.com:443、TLS handshake 成功・942 bytes) が **crash 無しで成功**。新規 crash report 無し。
- example の一時 diagnostic 足場は revert 済み（`app.rb` の `http_test`、`VMExecutor.swift` の auto-fetch / always-NSLog）。button 駆動の最終形で `rake ios:net:build` 成功。
- 修正の解説を **README.md に "Fork fix: picoruby-net POSIX recv-buffer allocator" セクション**として明記済み。

## 修正の保存場所（重要）
- fork checkout `/Users/bash/dev/src/github.com/bash0C7/picoruby-ble-darwin-port`、branch `picoruby-ble-darwin-port`（= R2P2-iOS の default `PICORUBY_REF`）に **commit `1a055b62`**（特例承認のもと posix port .c を fork に commit）。
- **未 push**。R2P2-iOS の `rake setup`/`refresh` はリモート `https://github.com/bash0C7/picoruby.git` から取得するため、clean fetch ではまだ反映されない。真の永続化＝この commit の **push**（次の TODO）。現 worktree の `vendor/picoruby`（branch `ios-posix-model`）には同一修正がローカルで載っており、今の build は動く。

## 次セッションの TODO（順序）
1. **fork へ push**（要 user 確認 / 1-way door）: `cd /Users/bash/dev/src/github.com/bash0C7/picoruby-ble-darwin-port && git push origin picoruby-ble-darwin-port`。push 後、clean `rake setup` で R2P2-iOS が修正込みを取得することを確認。
2. **R2P2-iOS 側の local commit**（origin が bash0C7/* なので local commit は確認不要）。未 commit:
   - `M README.md`（Fork fix セクション追加）
   - `M Rakefile`（`ios:net` namespace）
   - `?? build_config/r2p2-picoruby-ios-net-device.rb`
   - `?? examples/networking/`（app.rb / project.yml / Sources / Bridging-Header）
   - 注意: `examples/networking/Vendor/`（libmruby.a + headers stage 物）と `build/` は gitignore 対象か確認してから add。
3. **実機検証**（issue #6 完了必須要件、人間補助が要る物理操作）: networking example で **実機 TLS request 成功**を確認 + repl / vperiph / torch / watch も実機確認。実機 build は `rake ios:net:device:all`。
4. issue #6 をクローズ可能か判定。

## 検証コマンドメモ
- sim build+run: `rake ios:net:lib && rake ios:net:gen && rake ios:net:build`、install/launch は `rake ios:net:run`。
- C を直すたび `rake ios:net:lib` で libmruby.a 再生成が必要（app.rb だけの変更は `:build` のみ）。
- log: `xcrun simctl spawn <UDID> log stream --style compact --predicate 'eventMessage CONTAINS "[Networking]"'` を先に起動 → launch → 待機。
- crash report: `~/Library/Logs/DiagnosticReports/Networking-*.ips`（JSON は 2 行目以降）。

## 関連 memory
[[net-example-progress-and-hang]] / [[picoruby-net-vs-net-http-ios]] / [[fork-darwin-ports-only]]（今回 posix port .c を特例で fork に入れた経緯）/ [[issue6-ondevice-verification]] / [[darwin-ports-4gems-plan]]
