# Networking — Ruby で HTTP/TLS を行う (Net::HTTP over picoruby-socket + mbedTLS)

English: [README.md](README.md)

HTTP/TLS の往復処理はすべて Ruby です。`app.rb` が呼ぶ `Net::HTTP` は
upstream の `picoruby-net-http` gem のもので、その下の `picoruby-socket` の
darwin port (fork `port-darwin` の `ports/darwin/ssl_socket.c`) が iOS 上で生の
BSD socket を開き、mbedTLS で TLS handshake を行います。entropy は `picoruby-mbedtls`/`picoruby-rng` の
Darwin port が供給し、その実体は `-framework Security` 経由の
`SecRandomCopyBytes` です。OpenSSL も Apple の URL loading API
(`URLSession`/`CFNetwork`) も使わないため、それらの API のみを対象とする App
Transport Security は適用されません。このアプリの TLS は PicoRuby 自身のもの
で、デバイス上で動きます。

full-REPL gembox (`posix?=true` と `conf.ports :darwin, :posix` の port chain —
[root README の「全体の組み合わさり方」](../../../README_jp.md#全体の組み合わさり方) の gembox の説明を参照) を必要とする唯一の example です。他の example が使う
reduced VM では動きません。`picoruby-socket`/`picoruby-mbedtls`/`picoruby-rng` は
いずれも POSIX 前提の `build.posix?` 分岐を想定しているためです。

## 仕組み

FETCH ボタンを押すと、SwiftUI から mbedTLS まで一続きの呼び出しが走ります。
bridge より下の層はすべて Ruby と picoruby-socket の C です。

```
[SwiftUI FETCH button]
  --VMExecutor.shared.call("fetch")-->  $app (Ruby, NetApp)  -->  Net::HTTP.new(HOST, 443).get(PATH)
    --> picoruby-net-http (Ruby)                   SSLSocket.open(host, port, ctx)
    --> picoruby-socket (mruby glue)               src/mruby/ssl_socket.c
    --> ports/darwin/ssl_socket.c                  raw BSD socket + mbedTLS handshake
    --> mbedTLS entropy source                     picoruby-mbedtls Darwin port -> SecRandomCopyBytes
```

`VMExecutor.swift` は onAppear で VM を 1 回だけ起動し
(`virtual-peripheral`/`iphone-torch` と同じ persistent VM 方式)、`vm_open` が
返った直後に `call("fetch")` を自動実行します。これにより手動タップなしで
TLS 往復の結果が `devicectl ... process launch --console` から読めます
(NSLog にミラーされるため)。FETCH ボタンを押せば何度でも再実行できます。

`app.rb` はプレーンテキストの resource としてアプリに同梱され、VM 起動時に
PicoRuby の prism compiler がアプリ内で実行時コンパイルします。

- `app.rb` の `HOST`/`PATH` を書き換えて再インストールすれば、`libmruby.a` や
  Swift 層を再ビルドすることなくリクエスト先が変わります。
- レスポンスが返ってくれば、Darwin entropy port を使った mbedTLS handshake が
  iOS 上で完了した証拠になります。その全体を動かしているのはこの Ruby
  ファイルだけです。
- 既知の制限 (`app.rb` の `fetch` 内コメント参照): iOS には mbedTLS が検証に使える
  PEM の CA bundle が無いため、demo は `verify_mode = SSLContext::VERIFY_NONE` を
  設定しています。handshake は完了しますが server certificate の検証は行いません。
  検証するには CA の PEM を resource として同梱し `SSLContext#ca=` に渡します。
  この example が示すのは接続と handshake であって、信頼判断ではありません。

## 依存

この example は、`picoruby-socket` の darwin port (BSD socket + mbedTLS) を含む
`vendor/picoruby` でのみ動きます。default の fetch 先 (`bash0C7/picoruby` の
`port-darwin` branch) には含まれています。root README の [Vendor fork](../../../README_jp.md#vendor-fork) を参照してください。upstream の `picoruby/picoruby` には posix port しかなく、
その TLS は iOS に無い OpenSSL を link します。

## ビルドと実行

前提: フル版の `Xcode.app`、iOS SDK、`xcodegen` (`rake check` で検証できます)。

### Simulator

```sh
rake ios:net:all      # cross-build libmruby.a -> xcodegen -> build -> launch
```

### 実機

本物の TLS handshake を行います。署名済みの iOS device を接続しておいて
ください。初回の実機ビルドの前に、`project.yml` の
`DEVELOPMENT_TEAM: YOUR_TEAM_ID` を自分の Team ID に置き換えてください —
詳細は root README の [実機ビルド](../../../README_jp.md#実機ビルド) を参照
してください。

```sh
rake ios:net:device:all
```

実機では、FETCH のタップ (または起動時の auto-fetch) で
`handshake OK, response received (N bytes)` と `status: HTTP/1.1 200 OK` が
ログに出ます。

## 個別の rake タスク

pipeline の各ステップは個別の task としても呼べます。

- `rake ios:net:lib` — Simulator 向け `libmruby.a` を picoruby-net-http +
  socket/mbedTLS/rng darwin ports 込みで cross-build し、`Vendor/` 配下に配置
- `rake ios:net:gen` — `project.yml` から `Networking.xcodeproj` を生成
- `rake ios:net:build` — Simulator 向けにアプリをビルド
- `rake ios:net:run` — Simulator を起動してインストール・launch
- `rake ios:net:device:lib` — device SDK 向けに `libmruby.a` を cross-build
- `rake ios:net:device:build` — 接続した device 向けに署名付きビルド
- `rake ios:net:device:run` — 接続した device にインストールして launch
- `rake ios:net:device:all` — device 向け full pipeline: lib -> gen -> build -> run
