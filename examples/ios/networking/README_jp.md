# networking — RubyからのHTTPとTLS

English: [README.md](README.md)

HTTPS GETの往復すべてをPicoRubyがやるexampleです。`app.rb`は picoruby の
`picoruby-net-http` gemの`Net::HTTP`を`picoruby-socket`の上で呼びます。iOSでは
`picoruby-socket`のdarwin portが生のBSDソケットを開き、TLSハンドシェイクを
mbedTLSで走らせます。エントロピーは`picoruby-mbedtls`と`picoruby-rng`のdarwin
port（`SecRandomCopyBytes`。`-framework Security`でリンク）が供給します。

OpenSSLは一切関与せず、AppleのURL読み込みAPI（`URLSession`も`CFNetwork`も）も
使いません。App Transport SecurityはそれらのAPIだけを対象とする仕組みなので、
ここには適用されません。このアプリのTLSはデバイス上で動くPicoRuby自身のものです。

## しくみ

FETCHボタンがSwiftUIからmbedTLSまでの呼び出し連鎖を1本駆動します。ブリッジより
下はすべてRubyか picoruby-socket のCです。

```
[SwiftUI の FETCH ボタン]
  --VMExecutor.shared.call("fetch")-->  $app（NetApp、Ruby）
    --> Net::HTTP.new(HOST, 443).get(PATH)   picoruby-net-http（Ruby）
    --> SSLSocket.open(host, port, ctx)      picoruby-socket（mruby glue）
    --> ports/darwin/ssl_socket.c            生の BSD ソケット + mbedTLS ハンドシェイク
    --> picoruby-mbedtls の darwin port      SecRandomCopyBytes 由来のエントロピー
```

`VMExecutor`はonAppearで1度VMを起動し（`repl`以外のexampleが共有する永続VMの形）、
`vm_open`が返り次第`call("fetch")`を呼びます。ログ行は`NSLog`にも流れるので、
手でタップしなくても
`xcrun devicectl device process launch --console`から結果が読めます。FETCH
ボタンは対話的な再実行用です。

`app.rb`はプレーンテキストのリソースとして同梱され、起動時にアプリ内のprism
コンパイラがコンパイルします。`HOST`や`PATH`を書き換えて入れ直せば、
`libmruby.a`もSwift層も再ビルドせずにリクエストが変わります。レスポンスが返って
きたということは、そのRubyファイルだけを起点に、darwinのエントロピーportを使った
mbedTLSハンドシェイクがiOS上で成立したということです。

### 証明書検証は意図的に無効

`app.rb`は`http.verify_mode = SSLContext::VERIFY_NONE`を設定しています。iOSは
mbedTLSが検証に使えるPEMのCAバンドルを積んでいないため、ハンドシェイクは成立
しますがサーバ証明書は検証されません。このexampleが示すのは疎通とハンドシェイク
であって、信頼判断ではありません。

実際に検証したい場合は、CAのPEMをアプリのリソースとして同梱し、コンテキストに
渡します。`SSLContext#set_ca_pem`がPEMの中身を、`#ca_file=`がパスを受け取ります。

## gem集合

このexampleと[repl](../repl/README_jp.md)の2つが、他exampleの縮小版ではなく
フルREPLのgembox集合（`mruby-posix` + `core` + `stdlib` + `shell`）を使います。
好みの問題ではありません。`picoruby-socket`・`picoruby-mbedtls`・`picoruby-rng`は
いずれもPOSIX形のビルドを前提に分岐しており、縮小版の設定はそれを満たしません。

`build_config/r2p2-picoruby-ios-net-{sim,device}.rb`はそのgembox集合に
`picoruby-net-http`を足したものです。`picoruby-net-http`自身が
`picoruby-socket`と`picoruby-uri`を引き込みます。この設定はexample専用なので、
`repl`側の設定はnetworkingと無縁のまま、socketとTLSの表面なしでリンクし続けます。

## 依存

このexampleには`picoruby-socket`のdarwin portを持つ`vendor/picoruby`が要ります。
既定の取得元（`bash0C7/picoruby`の`port-darwin`ブランチ）はそれを含みます。
[vendorの取得元](../../../README_jp.md#vendorの取得元)を参照してください。
upstreamの`picoruby/picoruby`はposix portしか持たず、そのTLSはiOSに存在しない
OpenSSLをリンクします。

## ビルドと実行

前提はフルの`Xcode.app`、iOS SDK、`xcodegen`です。`rake check`で確認できます。

### Simulator

```sh
rake ios:net:all      # lib -> gen -> build -> run
```

### 実機

デバイス自身のネットワークスタックを通る本物のTLSハンドシェイクです。最初の実機
ビルドの前に、`project.yml`の`DEVELOPMENT_TEAM: YOUR_TEAM_ID`を自分のTeam IDに
置き換えてください。詳細は
[実機で動かす](../../../README_jp.md#実機で動かす)を参照。

```sh
rake ios:net:device:all
```

成功すると、ログに`handshake OK, response received (N bytes)`に続いて
`status: HTTP/1.1 200 OK`が出ます。

## 個別タスク

パイプラインの各段は単独タスクとしても呼べます。

| タスク | 内容 |
|---|---|
| `rake ios:net:lib` | Simulator SDK向けに`libmruby.a`をクロスビルドし`Vendor/`へ配置 |
| `rake ios:net:gen` | `project.yml`から`Networking.xcodeproj`を生成 |
| `rake ios:net:build` | Simulator向けにビルド |
| `rake ios:net:run` | Simulatorを起動しインストールしてlaunch |
| `rake ios:net:observe` | 固定Simulatorで繰り返し起動し各runを分類 |
| `rake ios:net:device:lib` | device SDK向けに`libmruby.a`をクロスビルド |
| `rake ios:net:device:check` | 署名なしでgeneric device向けにリンク（実機不要） |
| `rake ios:net:device:build` | 接続済みデバイス向けに署名してビルド |
| `rake ios:net:device:run` | 接続済みデバイスにインストールしてlaunch |
| `rake ios:net:device:all` | 実機パイプライン一式 |
