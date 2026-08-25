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

picorubyのmrubyビルド（`MRuby::CrossBuild`）は`arm64_32`を直接ターゲットに
しません。archフラグを明示しなければホストarchか`arm64`のオブジェクトを吐きます。
`rake watchos:led:device:lib`が1タスクでその穴を埋めます。

1. `build_config/r2p2-picoruby-watchos-device.rb`でクロスビルドする。
2. `build_config/recompile_arm64_32.rb`を走らせる。これはビルドディレクトリを
   歩き、各オブジェクトのソースを`.d`のdepfileから特定し、`-arch arm64_32`で
   コンパイルし直し、`arm64_32`だけの`libmruby.a`を再アーカイブする。
3. 結果を`Vendor/lib`へ再配置する。

ビルド設定の`cc.flags`自体が既に`-arch arm64_32`を指しているので、通常このスクリプト
の再コンパイル対象は0件です。Xcodeへ渡る前にアーカイブが`arm64_32`のみであることを
確かめるセーフティネットとして働きます。

### ABI defineの単一の真実

`mrb_value`と`mrb_state`のレイアウトを決めるdefine（`MRB_INT64`、
`MRB_NO_BOXING`、`MRB_BASELINE_PROFILE=1`ほか）は3つの別々のコンパイルに読まれ、
1バイトも違わず一致していなければなりません。食い違うと、最終アーカイブが異なる
構造体レイアウトのオブジェクトを混ぜ、実行時にメモリを壊します。

| コンパイル | defineの出どころ |
|---|---|
| `rake watchos:led:device:lib`（mrubyのオブジェクト） | `build_config/r2p2-picoruby-watchos-device.rb` |
| `recompile_arm64_32.rb`（arm64_32のパス） | 自前のリストを持たず、同じビルド設定から`conf.cc.defines`をパースする |
| Xcode（`picoruby_bridge.c`とアプリ） | `project.yml`の`GCC_PREPROCESSOR_DEFINITIONS` |

`MRB_BASELINE_PROFILE=1`がビルド設定に書かれていない点に注意してください。設定が
`PICORB_PLATFORM_POSIX`を立てるので`picoruby-mruby`がこのdefineをbuild-wideに
追加します。`sizeof(mrb_state)`を変えるため、`project.yml`側もこれを写す必要が
あります。

### forkとexec抜きの`mruby-io`

`PICORB_PLATFORM_POSIX`を立てると`mruby-io`が入りますが、そのposix HALは
`IO.popen`を`fork`と`exec`で実装しています。watchOS SDKはどちらも禁じているので、
このHALはそのままではコンパイルできません。`mruby-io`はupstream mrubyのsubmodule
なので手を入れず、代わりにmrubyの外部HAL provider規約（`hal-<short>-<conf>`という
名前のgemがportのオブジェクトを置き換える）を使います。
`conf.gem core: "hal-io-darwin"`が、同じコードからspawnだけを抜いたものを供給
します。iOSとmacOSにこれは不要で、posix HALのままです。

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
