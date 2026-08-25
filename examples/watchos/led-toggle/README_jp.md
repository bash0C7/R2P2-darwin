# led-toggle — Apple Watch上で、RubyのLチカ

English: [README.md](README.md)

組み込みのhello worldはLEDの点滅です。Apple WatchにLEDは無いので、このexampleは
画面上に代役を置きます。タップで切り替わる赤か青の円です。どちらの色が点いていて、
タップがそれをどう変えるかは`app.rb`にあり、時計自身の上のPicoRuby VMで動きます。

watchOSの単独アプリ（`WKWatchOnly`）で、実機のApple Watch（`arm64_32`）と
watchOS Simulatorの両方向けにビルドします。

## しくみ

状態機械は`app.rb`、ただのRubyオブジェクトです。

```ruby
class LEDApp
  def initialize
    @state = "red"
  end

  def tick(_)
    print @state
  end

  def toggle(_)
    @state = @state == "red" ? "blue" : "red"
    print @state
  end
end

$app = LEDApp.new
puts "booted"
```

Swiftは色のロジックを1つも持たず、VMをホストして結果を中継するだけです。

```
ContentView（赤/青の円 Text、.onTapGesture）
        │
        ├─ .onAppear ──> VMExecutor.start ──> vm_open(app.rb)   永続 VM 1つ
        │                                       LEDApp.new, $app
        │
        ├─ 0.1s タイマー ──> vm_call($app, "tick")   ──> "red"/"blue" ──> Text を更新
        └─ タップ         ──> vm_call($app, "toggle") ──> @state を反転し新しい色を返す
```

`@state == "red" ? "blue" : "red"`を評価するのは時計上のmruby VMです。したがって
Swiftが描く色は、文字通りRubyが返したものです。`vm_call`はRubyのグローバル`$app`の
メソッドを呼び、そのメソッドが`print`した内容を文字列として返します。
`VMExecutor`はそれを、円を選ぶSwiftUIの`@State`へ写します。

## 技術的な要点

ここでSwiftUIより下にある仕事はすべて、PicoRuby VMを実機のApple Watch上でリンク
させ動かすためのものです。この機種のCPU ABIはAppleの他のどの製品とも違います。

### arm64_32 — 64bitコア上の32bitポインタ

実機のApple Watch（Series 4以降）は`arm64_32`、すなわちILP32で動きます。ARM64の
レジスタに32bitのポインタです。AppleシリコンMac上のSimulatorは普通の64bit
`arm64`なので、Simulatorが緑でも時計については何も証明しません。

ILP32が壊すのは、まさに`mrb_value`のメモリ表現です。word boxingもNaN boxingも、
タグとポインタを1つのマシンワードに詰め、そのワードが64bitポインタを保持すると
仮定します。`arm64_32`ではどちらも成立しません。このビルドは`MRB_NO_BOXING`と
`MRB_INT64`を使います。`mrb_value`は構造体（unionと型タグ）になり、32bitポインタは
unionの中に詰めずに置かれ、整数は64bitのままです。時計上で正しいboxingの選択は
これだけです。

### arm64_32のアーカイブを作る

picorubyのmrubyビルドは`arm64_32`を直接ターゲットにしません。archフラグを明示
しなければホストarchか`arm64`のオブジェクトを吐きます。
`rake watchos:led:device:lib`がその穴を埋めます。クロスビルドしたあと
`build_config/recompile_arm64_32.rb`を走らせ、Xcodeへ渡る前に`arm64_32`だけの
`libmruby.a`を再アーカイブします。このスクリプトを自分で叩く必要はありません。
タスクがやります。

### forkもexecも使えない

watchOS SDKは`fork`と`exec`を禁じています。`puts`の提供元でもある`mruby-io`は
`IO.popen`をまさにその2つで実装しているため、ビルドは代わりのもの
（`hal-io-darwin`）を差し込みます。同じコードからspawnだけを抜いたものです。
したがって時計の上では`IO.popen`が使えません。`mruby-io`のそれ以外はiOSと同じに
振る舞います。

### 大きなVMスレッドスタック

watchOSが`DispatchQueue`のワーカースレッドに与えるスタックは、mruby VMとprism
コンパイラの初期化には小さすぎます。そこで`VMExecutor`はVMを、4MBのスタックを
明示した専用の`Thread`（`Thread.stackSize`）上で走らせ、すべてのVM呼び出しをその
スレッドのシリアルキューに固定します。VMの生存期間全体がシングルスレッドに保たれ
ます。

## ファイル

VM・Cブリッジ（`../../../bridge`）・ビルド設定（`../../../build_config`）は
リポジトリのルートにあります。このディレクトリにあるのはアプリと`app.rb`です。

- `app.rb` — 状態機械（`LEDApp#tick`、`#toggle`）。リソースとして同梱。
- `Sources/VMExecutor.swift` — VMを持つ4MBスタックの専用スレッド、0.1秒の
  tickタイマー、`toggle()`。
- `Sources/ContentView.swift` — 赤/青の円`Text`、切り替えの`.onTapGesture`、
  起動の`.onAppear`。
- `Sources/App.swift` — `@main`のwatchOSアプリエントリポイント。
- `Sources/WatchLEDToggle-Bridging-Header.h` — C VMブリッジをSwiftへ公開。
- `project.yml` — xcodegenのプロジェクト定義。`WKWatchOnly`、`-lmruby`のリンク、
  ABI defineの写し。

## ビルドと実行

### Simulator

```sh
rake watchos:led:all     # lib -> gen -> build -> watch sim 起動 -> install -> launch
```

### 実機

最初の実機ビルドの前に、`project.yml`の`DEVELOPMENT_TEAM: YOUR_TEAM_ID`を自分の
Team IDに置き換えてください。詳細は
[実機で動かす](../../../README_jp.md#実機で動かす)を参照。

```sh
rake watchos:led:device:all   # lib（+ arm64_32 パス）-> gen -> build -> install -> launch
```

段階的に実行する場合:

```sh
rake watchos:led:device:lib
rake watchos:led:gen
rake watchos:led:device:build
rake watchos:led:device:run     # ペアリング済みの時計を xcrun devicectl で探す
```

`rake watchos:led:device:check`は署名を無効にしてgeneric watchOS device向けに
リンクするので、時計を繋がずにSDKレベルの破損を捕まえられます。

起動するとコンソールに`booted`、続いて`VM opened`が出ます。起動用のRubyが走り
VMが生きているということです。画面をタップすると円が赤と青の間で切り替わります。

実機での注意:

- bundle idごとに初回起動時、実機側での信頼操作が1度だけ必要です。
- 時計がロックされていると`:run`が
  `FBSOpenApplicationErrorDomain error 7 Locked`で失敗します。解除して再実行して
  ください。
