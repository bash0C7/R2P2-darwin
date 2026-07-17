# repl — デバイス上で Ruby を評価する

English: [README.md](README.md)

テキストエディタ・Run ボタン・出力ビューを備えた SwiftUI アプリ
(`PicoRubyRunner`) です。入力した Ruby をデバイス上でコンパイル・実行し、
キャプチャした出力を表示します。

## 仕組み

この example に同梱の `.rb` はありません。実行される Ruby は、実行時にその場で
入力したものです。クロスビルドした `libmruby.a` は VM 内に prism コンパイラを
含むため、ソースは事前コンパイルではなくデバイス上でコンパイル・実行されます。

Run のたびに bridge 呼び出しが 1 回行われます。

```
ContentView (TextEditor + Run)
        │  repl_eval(source)            bridge/picoruby_bridge.c
        ▼
  使い捨ての新規 PicoRuby VM           prism がソースをコンパイルし、VM が実行
        │  stdout + stderr をキャプチャ  (未捕捉例外はアプリを落とさず
        ▼                               backtrace 文字列として現れる)
  出力ビューに表示される String
```

- `repl_eval(const char *src)` (`../../../bridge/picoruby_bridge.h`) は新規 VM を
  開いて `src` をコンパイル・実行し、キャプチャした stdout+stderr を malloc した
  文字列として返します。コンパイル診断や未捕捉例外の backtrace も含まれ、
  解放は呼び出し側の責務です。
- Run ごとに新しい VM を使うため、各評価はクリーンな状態から始まります。
- `ContentView.run()` はこれを background thread で呼び、返された文字列を
  free します。NULL が返った場合 (アロケーション/セットアップ失敗) は
  `(VM failed to start)` と表示します。

## ファイル構成

Ruby VM・bridge・build config はリポジトリルート (`../../../bridge`、
`../../../build_config`) にあり、このディレクトリはアプリ本体だけを持ちます。

- `Sources/App.swift` — `@main` のアプリエントリです。`WindowGroup` を 1 つ持ちます。
- `Sources/ContentView.swift` — エディタ + Run + 出力ビューです。`repl_eval` を呼びます。
- `Sources/PicoRubyRunner-Bridging-Header.h` — C bridge を Swift に公開します。
- `project.yml` — xcodegen プロジェクトです。bridge のソースをコンパイルし、
  `Vendor/lib` に stage された `libmruby.a` を `-lmruby` でリンクします。

## ビルドと実行

iOS Simulator と接続した実機の両方で動きます。

素の `ios:*` タスクは `ios:repl:*` の alias なので、`rake ios` がこのアプリを
ビルドします。

### Simulator

```
rake ios                  # Simulator: lib -> gen -> build -> run (headless)
```

### 実機

初回の実機ビルドの前に、`project.yml` の `DEVELOPMENT_TEAM: YOUR_TEAM_ID` を
自分の Team ID に置き換えてください。詳細は
[実機ビルド](../../../README_jp.md#実機ビルド) を参照してください。

```
rake ios:device:all       # 接続済み・署名済みデバイス: lib -> gen -> build -> run
```

## 既知の制約

VM は `build_config/r2p2-picoruby-ios-repl-{sim,device}.rb` によって full-REPL
gem set でビルドされるため、`core`/`stdlib` の Ruby サーフェスをフルに使えます。

- gembox: `mruby-posix` + `core` + `stdlib` + `shell`。gem ごとに Darwin port を
  POSIX 版より優先して選択します (`conf.ports :darwin, :posix`)。
- networking 系 gem と OpenSSL はこの build config から除外されています。
- bridge は毎回の評価の先頭に、core の `print` で定義した 1 行の `puts` shim を
  付加します。物理 1 行なので、診断メッセージの行番号は入力からちょうど 1 だけ
  ずれます。
- 全体像はリポジトリ README の "Constraints worth knowing" を参照してください。
