# repl — デバイス上でRubyを評価する

English: [README.md](README.md)

テキストエディタとRunボタンと出力ビューを持つSwiftUIアプリ（`PicoRubyRunner`）
です。打ち込んだRubyがそのままデバイス上でコンパイル・実行され、捕捉した出力が
画面に返ってきます。

これが入口となるexampleです。素の`ios:*` rakeタスクは`ios:repl:*`のエイリアス
なので、`rake ios`はこのアプリをビルドして起動します。

## しくみ

同梱の`.rb`はありません。Rubyは実行時に打ち込むものです。クロスビルドした
`libmruby.a`はprismコンパイラをVM内に抱えているので、ソースはMac上で事前に
ではなく、デバイス自身の上でコンパイルされます。

Run 1回がブリッジ呼び出し1回に対応します。

```
ContentView（TextEditor + Run）
        │  repl_eval(source)                  bridge/picoruby_bridge.c
        ▼
  使い捨ての新しい PicoRuby VM                prism がソースをコンパイルし VM が実行
        │  捕捉した stdout + stderr           未捕捉例外はアプリを落とさず
        ▼                                     バックトレースとして印字される
  出力ビューに表示される String
```

- `repl_eval(const char *src)`（宣言は`../../../bridge/picoruby_bridge.h`）は
  新しいVMを開き、`src`をコンパイル・実行し、stdoutとstderrに書かれたすべて
  （コンパイル診断と未捕捉例外のバックトレースを含む）をmalloc済み文字列で
  返します。解放は呼び出し側の責務です。
- 出力の捕捉は、呼び出しの間だけファイルディスクリプタ1と2を一時ファイルへ
  リダイレクトする方式です。したがってRubyレベルの`print`だけでなく、VMやC gem
  が書いたものも捕まります。
- Runごとに新しいVMなので、評価は毎回まっさらな状態から始まります。VMのヒープは
  呼び出しごとに確保され、戻るときに丸ごと解放されます。
- `ContentView.run()`はこれをバックグラウンドスレッドで呼び、返った文字列を
  解放します。NULLが返った場合（確保失敗またはVM初期化失敗）は
  `(VM failed to start)`と表示します。

このアプリはonAppear時にも1度実行するので、起動しただけで既定スニペットの結果が
出ています。`rake ios:repl:observe`が起動時のコンソール出力から`hello 3`を
確認できるのはそのためです。

## ファイル

VM・Cブリッジ・ビルド設定はリポジトリのルート（`../../../bridge`、
`../../../build_config`）にあります。このディレクトリにあるのはアプリだけです。

- `Sources/App.swift` — `@main`のエントリポイント。`WindowGroup`が1つ。
- `Sources/ContentView.swift` — エディタ・Runボタン・出力ビュー。`repl_eval`を呼ぶ。
- `Sources/PicoRubyRunner-Bridging-Header.h` — CブリッジをSwiftへ公開する。
- `project.yml` — xcodegenのプロジェクト定義。ブリッジのソースをコンパイルし、
  `Vendor/lib`に配置された`libmruby.a`へ`-lmruby`でリンクする。
- `aot-kernel/bench_tick.{rb,rbs}` — AOTカーネル。インタプリタのベースラインと
  ネイティブビルドの両方にとって唯一のソース。
  [AOTネイティブカーネル](#aotネイティブカーネル)を参照。
- `picoruby-bench_tick/` — 生成されるmrbgem。リポジトリには入っていません。
  gitignoreしてあり、`aot-kernel/`から再生成します。

`Vendor/`は`rake ios:lib`が生成するもので、ソースディレクトリではありません。

## ビルドと実行

### Simulator

```sh
rake ios          # lib -> gen -> build -> run
```

式を打ち込んでRunを押します。

### 実機

最初の実機ビルドの前に、`project.yml`の`DEVELOPMENT_TEAM: YOUR_TEAM_ID`を自分の
Team IDに置き換えてください。詳細は
[実機で動かす](../../../README_jp.md#実機で動かす)を参照。

```sh
rake ios:device:all
```

## AOTネイティブカーネル

インタプリタと並べて、このexampleはRubyのメソッドを1つ、ビルドより前にネイティブ
コードへコンパイルしたものとして走らせます。両者をベンチマークで突き合わせるため
です。`bench_tick`（`aot-kernel/bench_tick.{rb,rbs}`）をmatzの
[spinel](https://github.com/matz/spinel)がコンパイルし、
[suppify](https://github.com/bash0C7/suppify)が`picoruby-bench_tick` mrbgemに
包みます。

`Sources/ContentView.swift`のseedはまずインタプリタ版とネイティブ版の結果が一致
することを確かめ、それから呼び出し1回あたりのバッチ長`n`をスイープします。物理の
iPhone 16eでは、1回の呼び出しに十分な計算を寄せてVM境界を越えるコスト（ディスパッチ、
引数検査、spinelの`setjmp`）が薄まると、ネイティブ版が約50倍に達します。インタプリタ
版はスイープを通してほぼ横ばいです。

### gemを再生成する

`picoruby-bench_tick/`は**リポジトリに入っていません**。gitignoreしてあり、カーネルの
ソースから再生成します。`vendor/picoruby`をvendorせずfetchするのと同じ扱いです。
spinelとsuppifyのバージョンが同じなら生成は決定論的なので、このgemはソースではなく
ビルド生成物です。

spinelとsuppifyは外部ツールで、コンパイラを探すのと同じ要領で場所を渡します。

```sh
cd examples/ios/repl/aot-kernel
SPINEL=/path/to/spinel/spinel SPINEL_LIB=/path/to/spinel/lib \
  ruby /path/to/suppify/suppify.rb bench_tick.rb -o bench_tick -t picoruby -d ..
#   -> ../picoruby-bench_tick/
```

`rake ios:repl:lib`はビルド設定の`conf.gem` 1行でこのgemをリンクするので、ビルド前に
再生成しておいてください。適用と組み込みの完全な手順は、自分のメソッドに適用する
やり方も含めて`aot-embed` skill（`.claude/skills/aot-embed/`）にあります。

## 使えるRubyの範囲

このexampleは`build_config/r2p2-picoruby-ios-repl-{sim,device}.rb`がフルREPLの
gem集合でビルドします。`core`と`stdlib`の表面がすべて揃っており、本リポジトリの
exampleの中では最も広い範囲です。

gemboxは`mruby-posix` + `core` + `stdlib` + `shell`。networkingは入っていません。
RubyからHTTPとTLSを使う話は、この同じgem集合の上にsocketとmbedTLSのスタックを
リンクする[networking example](../networking/README_jp.md)にあります。
