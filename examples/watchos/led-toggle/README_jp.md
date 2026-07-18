# led-toggle — Ruby で書いた LED 点滅を Apple Watch で動かす

English: [README.md](README.md)

組み込みの「hello world」といえば LED の点滅です。Apple Watch には LED がないので、
この example では画面上の赤と青の円を LED に見立て、タップで切り替えます。
「いまどちらの色か」「タップでどう反転するか」という状態機械は `app.rb` にあり、
watch 上の PicoRuby VM で動きます。

watchOS 単体アプリ (`WKWatchOnly`) として、実機の Apple Watch (`arm64_32`) と
watchOS Simulator の両方に向けてビルドします。

## 仕組み

LED の状態機械は `app.rb` にある素の Ruby オブジェクトです。

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

色のロジックを Swift は一切持ちません。Swift は VM をホストして結果を中継するだけです。

```
ContentView (赤と青の円の Text, .onTapGesture)
        │
        ├─ .onAppear ──> VMExecutor.start ──> vm_open(app.rb)      永続 VM を 1 つ
        │                                       LEDApp.new, $app
        │
        ├─ 0.1s timer ──> vm_call($app, "tick")   ──> "red"/"blue" ──> Text を更新
        └─ tap        ──> vm_call($app, "toggle") ──> @state を反転し新しい色を返す
```

`@state == "red" ? "blue" : "red"` を評価するのは watch 上の mruby VM で、Swift が
描画する色は Ruby が返した値そのものです。`vm_call` は Ruby のグローバル `$app` の
メソッドを呼び出し、そのメソッドが `print` した出力を文字列として返します。
`VMExecutor` がそれを SwiftUI の `@State` に反映し、赤と青の円のどちらを表示するかが
決まります。

## エンジニアリングノート

SwiftUI の下にあるのは、PicoRuby VM を実機の Apple Watch でリンクして動かす作業
です。watch の CPU ABI は Apple の他のどの製品とも異なります。

### arm64_32 — 64-bit コア上の 32-bit ポインタ ABI

実機の Apple Watch (Series 4 以降) は `arm64_32` (ILP32) で動きます。レジスタは
ARM64 ですが、ポインタは 32-bit です。Apple silicon Mac 上の Simulator は通常の
64-bit `arm64` なので、Simulator で動いても実機で動く保証にはなりません。この ILP32
環境が壊すのが、まさに `mrb_value` のメモリ表現です。

- word boxing / NaN boxing はタグとポインタを 1 machine word に詰め込み、64-bit
  ポインタを前提とします。`arm64_32` ではどちらも成立しません。
- そのためこのビルドは `MRB_NO_BOXING` + `MRB_INT64` を使います。`mrb_value` は
  struct (union + type tag) になり、32-bit ポインタはそのまま union に収まり、整数は
  64-bit のままです。watch 上で正しく動く boxing の選択はこれだけです。

### arm64_32 の libmruby.a を作る

picoruby の mruby build (`MRuby::CrossBuild`) は `arm64_32` を直接ターゲットには
しません。明示的な arch flag がなければ host アーキテクチャ / `arm64` のオブジェクトが
生成されます。このギャップを `rake watchos:led:device:lib` が 1 タスクで埋めます。

- まず `build_config/r2p2-picoruby-watchos-device.rb` で cross-build し、続いて
  `build_config/recompile_arm64_32.rb` を実行して結果を `Vendor/lib` に再配置します。
  Xcode に渡る archive は常に `arm64_32` のみです。
- `recompile_arm64_32.rb` は build ディレクトリを走査し、各オブジェクトのソースを
  `.d` depfile から特定して `-arch arm64_32` で再コンパイルし、`arm64_32` のみの
  `libmruby.a` を作り直します。
- build_config の `cc.flags` 自体が `-arch arm64_32` を指定しているため、この
  スクリプトの再コンパイル対象は 0 個で、archive が `arm64_32` のみであることを
  検証する safety net として働きます。

### ABI defines の single source of truth

`mrb_value` のレイアウトを決める defines (`MRB_INT64`、`MRB_NO_BOXING`、
`MRB_CONSTRAINED_BASELINE_PROFILE` など) は 3 つのコンパイラから読まれ、byte 単位で
一致している必要があります。一致しないと、最終 archive に `mrb_value` / `mrb_state`
のレイアウトが異なるオブジェクトが混ざり、実行時にメモリを破壊します。

- `rake watchos:led:device:lib` (mruby オブジェクト) — defines は
  `build_config/r2p2-picoruby-watchos-device.rb` から
- `recompile_arm64_32.rb` (arm64_32 再コンパイル) — 独自のリストを持たず、同じ
  build_config から `conf.cc.defines` をパースします。再 archive する mruby
  オブジェクトから乖離することがありません。
- Xcode (`picoruby_bridge.c` とアプリ) — `project.yml` の
  `GCC_PREPROCESSOR_DEFINITIONS`

### 大きめの VM スレッドスタック

watchOS が `DispatchQueue` の worker スレッドに与えるスタックは小さく、mruby VM +
prism コンパイラの初期化には足りません。`VMExecutor` は VM を専用の `Thread` で
動かし、`Thread.stackSize` で 4 MB のスタックを明示的に確保します。すべての VM
呼び出しはそのスレッドに固定された serial queue に流すため、VM のライフタイム全体が
シングルスレッドに保たれます。

## ファイル構成

VM、C bridge (`../../../bridge`)、build config (`../../../build_config`) は repo
root にあります。このディレクトリにあるのはアプリ本体と `app.rb` です。

- `app.rb` — LED の状態機械 (`LEDApp#tick` / `#toggle`)。リソースとしてバンドル
  されます。
- `Sources/VMExecutor.swift` — VM を所有する 4 MB スタックの専用スレッド、0.1 秒の
  tick タイマー、`toggle()`
- `Sources/ContentView.swift` — 赤と青の円を表示する `Text`。`.onTapGesture` で
  toggle、`.onAppear` で boot
- `Sources/App.swift` — `@main` の watchOS アプリエントリ
- `Sources/WatchLEDToggle-Bridging-Header.h` — C の VM bridge を Swift に公開
- `project.yml` — xcodegen のプロジェクト定義。`WKWatchOnly`、`-lmruby` のリンク、
  ABI defines のミラー

## ビルドと実行

watchOS Simulator と実機の Apple Watch の両方で動きます。

### Simulator

```sh
rake watchos:led:all     # lib -> gen -> build -> watch sim を boot -> install -> launch
```

### 実機

初回の実機ビルドの前に、`project.yml` の `DEVELOPMENT_TEAM: YOUR_TEAM_ID` を
自分の Team ID に置き換えてください。詳細は
[実機ビルド](../../../README_jp.md#実機ビルド) を参照してください。

```sh
rake watchos:led:device:all   # lib (+ arm64_32 再コンパイル) -> gen -> build -> install -> launch
```

段階的に実行する場合は `rake watchos:led:device:lib && rake watchos:led:gen &&
rake watchos:led:device:build && rake watchos:led:device:run` です。`:run` は
ペアリング済みの watch を `xcrun devicectl list devices` で自動的に見つけます。

起動するとコンソールに `booted`、続いて `VM opened` が出ます (boot 用の Ruby が実行
され、VM が生きている状態です)。画面をタップすると円の色が赤と青で切り替わります。

実機での注意点:

- この bundle id の初回起動時には、デバイス上で一度だけ信頼 (trust) の操作が必要です。
- watch がロックされていると `:run` は `FBSOpenApplicationErrorDomain error 7 Locked`
  で失敗します。ロックを解除して再実行してください。
