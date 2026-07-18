# R2P2-darwin

[![CI](https://github.com/bash0C7/R2P2-darwin/actions/workflows/ci.yml/badge.svg)](https://github.com/bash0C7/R2P2-darwin/actions/workflows/ci.yml)

English: [README.md](README.md)

[PicoRuby](https://github.com/picoruby/picoruby)をApple製プラットフォームでビルド・
実行するためのリポジトリです。対象はmacOSホスト、iOS（Simulatorと署名済み実機）、
watchOSの3つ。ESP-IDF側のR2P2-ESP32と並ぶ、[R2P2ハーネス群](#r2p2という系列)の
Apple担当にあたります。

picorubyを静的ライブラリにクロスビルドし、薄いCブリッジを介してSwiftUIアプリに
リンクします。付属のexampleはアプリの振る舞いをすべてRubyファイル側に置いた構成
です。PicoRubyはprismコンパイラをVMに焼き込んでいるので、これらのアプリはデバイス
上で実行時にRubyソースをコンパイルして走らせます。

## クイックスタート

AppleプラットフォームでPicoRubyが動くまでの最短経路が、iOS Simulator上の`repl`
exampleです。Apple Developerアカウントも署名も要りません。

1. フルのXcode.appをインストールし（App Storeから。Command Line Toolsだけでは
   足りません）、ツールチェーンをそちらへ向けます:

   ```sh
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -license accept
   ```

2. プロジェクトジェネレータを入れます:

   ```sh
   brew install xcodegen
   ```

3. cloneして前提条件を確認します:

   ```sh
   git clone https://github.com/bash0C7/R2P2-darwin.git
   cd R2P2-darwin
   rake check
   ```

4. ビルドして起動します:

   ```sh
   rake ios
   ```

`rake ios`はpicorubyを`vendor/picoruby`へ取得し、Simulator SDK向けに
`libmruby.a`をクロスビルドし、Xcodeプロジェクトを生成し、アプリをビルドして
起動します。アプリに`puts "hello #{1 + 2}"`と打ってRunを押すと`hello 3`が
出ます。コンパイルも実行もアプリ内のPicoRubyがやっています。

初回はサブモジュール込みでpicorubyをcloneするため約1.2GB、ビルド出力を
含めると作業ツリーは約3GBになります。Rakefileを動かすのは環境にあるRuby 2.7
以上なら何でも構いません（rbenv / asdf / システム）。`.ruby-version`は
バージョンマネージャ向けに4.0.5を固定しています。

## このリポジトリの位置づけ

### R2P2という系列

R2P2（Ruby Rapid Portable Platform）はPicoRubyのシェルです。ターゲット上で動く
対話的なRuby環境で、picorubyの中に`picoruby-r2p2` picogemとして存在します。
これと足元のVMを、あるプラットフォーム系列のビルドシステムへ載せる仕事は、独立した
*ハーネス*リポジトリの責務です。

| ハーネス | プラットフォーム系列 | picorubyの入手方法 |
|---|---|---|
| [picoruby/picoruby](https://github.com/picoruby/picoruby)内の`rake r2p2:*` | Raspberry Pi Pico（RP2040 / RP2350） | それ自体がpicorubyツリー |
| [R2P2-ESP32](https://github.com/picoruby/R2P2-ESP32) | ESP32系列、ESP-IDF経由 | `components/picoruby-esp32/picoruby`のgit submodule。upstreamのcommitに固定 |
| **R2P2-darwin**（本リポジトリ） | macOSホスト / iOS / watchOS、Xcode経由 | `rake setup`が`PICORUBY_REF`をgitignore対象の`vendor/picoruby`へclone |

依存の取り方が違うのは意図的です。R2P2-ESP32が必要とするport（`ports/esp32/`）は
既にupstreamにあるので、submoduleでupstreamを固定できます。R2P2-darwinはそうは
いきません。darwin portはこのハーネスと並行して開発されているため、固定された
submoduleではなく*可変refのfetch*であり、commitせずgitignoreします。その結果
`PICORUBY_REPO`と`PICORUBY_REF`がESP32側とは違って第一級のつまみになっており、
既定のrefがforkなのもそのためです（[vendorの取得元](#vendorの取得元)を参照）。

出てくるものも違います。PicoやESP32のビルドが産むのはファームウェアイメージ1つで、
R2P2は実質その全体です。Appleプラットフォームにはその枠がありません。アプリとは
Xcodeが組み立てる署名済みバンドルだからです。したがって本リポジトリの主たる成果物は
`libmruby.a`、つまりCブリッジ経由でSwiftUIアプリにリンクする静的ライブラリとしての
VMであり、単一ファームウェアではなくexampleアプリ群を提供します。R2P2シェルそのものは
picorubyがネイティブに動くmacOSホスト側に現れます。`rake macos:build`が
`picoruby-bin-r2p2`実行ファイルをビルドし、`rake macos:run`がそのシェルに入ります。

### portと、Apple固有glueの置き場所

picorubyの各mrbgemはアーキテクチャ依存のコードを`mrbgems/<gem>/ports/<arch>/`
（`rp2040` / `posix` / `esp32` / `darwin`）に分けて持ち、インターフェース
（`include/*.h`）は全portで完全に同一です。ハーネスがやるのはportの選択であって、
コアをforkすることではありません。

そのためR2P2-darwinが保持するのは、Apple向けportを選ぶMRubyビルド設定、SwiftとVMを
つなぐCブリッジ、そしてexampleアプリです。Apple固有のglueはここに置き、取得した
picorubyのツリーはpristineに保ってcommitしません。

### darwinはPOSIXプラットフォーム

iPhoneもApple WatchもMacもDarwin（XNU + BSD libc）で動きます。したがって本
リポジトリのビルド設定はすべて`PICORB_PLATFORM_POSIX`と
`PICORB_PLATFORM_DARWIN`を**両方**定義し、`conf.ports :darwin, :posix`を
設定します。

- `PICORB_PLATFORM_POSIX`は「libc・thread・fd・signalがある」ことをpicorubyに
  伝えます。VMを小さくする目的でこれを外すと、そんな問題を持たないシステムに
  MCU向けのport契約（hwclock、GPIO sleep、littlefs、watchdog）を要求すること
  になります。
- `PICORB_PLATFORM_DARWIN`はApple固有の差分を表します。BTstackではなく
  CoreBluetooth、iOSがsandboxする`/dev/urandom`ではなく
  `SecRandomCopyBytes`、制御端末を持たないこと。
- `conf.ports :darwin, :posix`は、gemが`ports/darwin/`を持てばそれを、
  無ければ`ports/posix/`を選びます。判定はgemごとにビルド時に行われます。

帰結が1つ、書けるRubyに効きます。`PICORB_PLATFORM_POSIX`が立つことで
`picoruby-mruby`が`mruby-io`と`mruby-task`を引き込むため、後述のいちばん小さい
gem集合でも`puts`・`print`・`sleep_ms`が使えます。

### vendorは1つ、ビルド出力も1箇所

`vendor/picoruby`の単一チェックアウトが全プラットフォームを賄い、ビルド出力は
すべて`./build`（`MRUBY_BUILD_DIR`）へ出るので、取得したソースは一切書き換わり
ません。

```sh
rake setup     # PICORUBY_REF を vendor/picoruby へ clone（各 :lib タスクが依存）
rake refresh   # 既存チェックアウトへ PICORUBY_REF を再取得
rake clean     # build/ と各 example の Vendor/ を削除
rake clobber   # clean に加えて vendor/picoruby も削除
```

| 変数 | 既定値 | 制御対象 |
|---|---|---|
| `PICORUBY_REPO` | `https://github.com/bash0C7/picoruby.git` | picorubyのソースリポジトリ |
| `PICORUBY_REF` | `port-darwin` | 取得するref — [vendorの取得元](#vendorの取得元)を参照 |
| `IOS_MIN` | `17.0` | iOSのdeployment target下限 |
| `WATCHOS_MIN` | `11.0` | watchOSのdeployment target下限 |
| `PICORUBY_BLE_GEMDIR` | vendorの`picoruby-ble` | BLE exampleが使うpicoruby-bleの別チェックアウト |
| `MRUBY_CONFIG` | `build_config/r2p2-picoruby-darwin.rb` | `macos:`ホストタスクのビルド設定 |

## Example

iOS / watchOSのexampleはいずれもSwiftUIアプリで、振る舞いは`app.rb`にあります。
`app.rb`はプレーンテキストのリソースとして同梱され、起動時にアプリ内のprism
コンパイラがコンパイルします。各exampleに個別のREADMEがあります。

| Example | rake namespace | 何を示すか |
|---|---|---|
| [ios/repl](examples/ios/repl/README_jp.md) | `ios:repl`（`ios`だけでも可） | アプリに打ち込んだRubyを実行時に評価する |
| [ios/networking](examples/ios/networking/README_jp.md) | `ios:net` | picoruby-socketのdarwin port経由の`Net::HTTP` — TLSはmbedTLS、`URLSession`もOpenSSLも使わない |
| [ios/virtual-peripheral](examples/ios/virtual-peripheral/README_jp.md) | `ios:vperiph` | CoreBluetooth上でRubyが書くBLE GATTペリフェラル |
| [ios/iphone-torch](examples/ios/iphone-torch/README_jp.md) | `ios:torch` | iPhone版の「Lチカ」。ライトをRubyのループで点滅させる |
| [ios/stackchan](examples/ios/stackchan/README_jp.md) | `ios:stackchan` | NUS経由で[Stack-chan](https://github.com/meganetaaan/stack-chan)を操るBLEセントラル |
| [ios/tilt-synth](examples/ios/tilt-synth/README_jp.md) | `ios:tiltsynth` | Device MotionからFM音源へ。音楽的マッピングはRuby側 |
| [watchos/led-toggle](examples/watchos/led-toggle/README_jp.md) | `watchos:led` | Apple Watch（`arm64_32`）上で動くRubyの状態機械 |
| [macos/ls](examples/macos/ls/README_jp.md) | — | `rake macos:single`のデモスクリプト |

どのnamespaceも同じ4ステップとそれを連結する`all`、さらに接続した実機に対して
同じことをする`device:`サブnamespaceを持ちます。

```sh
rake ios:torch:lib            # libmruby.a をクロスビルドし example の Vendor/ へ配置
rake ios:torch:gen            # project.yml から .xcodeproj を生成
rake ios:torch:build          # Simulator 向けにビルド
rake ios:torch:run            # Simulator を起動しインストールして launch
rake ios:torch:all            # 上記4つを順に実行

rake ios:torch:device:all     # 接続済み・署名済み iPhone に対する同じパイプライン
rake ios:torch:device:check   # 署名なしで generic device 向けにリンク（実機不要）
```

全タスクとその説明は`rake -T`で一覧できます。

## 実機で動かす

device系タスクは自動署名でビルドします。最初の実機ビルドの前に:

1. Xcode → Settings → AccountsでTeam IDを確認します。無料のApple IDでも
   構いません（Personal Teamが割り当てられます）。
2. 対象exampleの`project.yml`の`DEVELOPMENT_TEAM: YOUR_TEAM_ID`を自分の
   Team IDに置き換えます。チーム内でbundle idが衝突する場合は
   `bundleIdPrefix`も変更します。
3. 実機側でbundle idごとに1度だけ証明書を信頼します。設定 → 一般 →
   VPNとデバイス管理 → 自分のApple ID → 信頼。

無料のPersonal Teamには2つの制限が付きます。同時にインストールできるアプリは
3つまで（インストールエラー3002が上限到達のサインで、
`xcrun devicectl device uninstall app --device <UDID> <bundle-id>`で1つ外します）、
そしてプロビジョニングが7日で失効します。加えて、`device:run`が起動する時点で
デバイスのロックは解除されている必要があります。

`device:check`は実機を一切必要としません。署名を無効にしてgeneric device向けに
リンクするので、device SDK固有の破損（SDKがunavailableとしているAPI、device用
アーカイブに欠けているport symbol）を、署名セッション抜きで炙り出せます。

## macOSホスト

macOSではpicorubyは組み込みVMではなくネイティブに動くため、ホスト側タスクは
アプリではなくバイナリを産出します。出力先は`./build/host/bin`です。

```sh
rake macos:check                                # Xcode CLT / brew openssl@3 / Swift
rake macos:build                                # ./build/host/bin/{r2p2,picoruby}
rake macos:run                                  # r2p2 シェル
rake macos:run APP=path/to.rb                   # Ruby ファイルを1つ実行
rake macos:single APP=examples/macos/ls/ls.rb   # スクリプトを埋め込んだ単一バイナリ
```

ここではCommand Line Toolsで十分です。Homebrewの`openssl@3`が要るのは、ホスト
ビルドがnetworking gemboxを含むためだけです。ビルド設定は`MRUBY_CONFIG`で選び
ます。`r2p2-picoruby-darwin.rb`がホストのベース、
`r2p2-picoruby-darwin-ble.rb`がpicoruby-bleとpicoruby-picotestを足したもの、
`r2p2-picoruby-darwin-single.rb`が`macos:single`の裏で使われます。

BLE設定でビルドしたバイナリは、`./build/host/bin/picoruby`を直接実行する形では
動きません。macOSのTCCは、`NSBluetoothAlwaysUsageDescription`を宣言したアプリ
バンドルからLaunchServices経由で起動されたのでないプロセスのCoreBluetooth呼び
出しを、署名済み・許可済みであっても例外なく`SIGABRT`で落とします。本リポジトリ
はバイナリを産出するところまでを担い、それをバンドル化して`open -a`で起動する
のは利用側の責務です。実例は
[stackchan-picorubyの`pc/stackchan-pico`](https://github.com/bash0C7/stackchan-picoruby/tree/main/pc/stackchan-pico)
にあります。

## ビルドの検証

安いものから順に4つあります。

**`rake smoke`**は`build_config/r2p2-picoruby-host.rb`でpicorubyをホスト
ビルドし（全iOS設定が出発点とする共通のgem集合とport chainを同じく持ちます）、
`bridge/smoke_test.c`をリンクして実行します。ブリッジと
`ports/darwin/machine.c`に対する高速なgateであり、CIが毎pushで回しているのも
これです。

**`rake ios:<name>:device:check`**はdevice用アプリを署名なしでリンクし、
Simulatorビルドやホストビルドでは通ってしまうdevice SDK禁止事項を捕まえます。

**`rake ios:<name>:observe`**は振る舞いのgateです。ビルド済みアプリを固定した
Simulator上で`OBSERVE_N`回（既定5回）起動し、各runを分類します。

- *OK* — そのexampleの期待行が出力に現れ、かつ新規クラッシュレポートが無い。
  期待行はexampleごとにRakefileの`IOS_EXAMPLES`表で宣言しています（replなら
  `hello 3`、torchなら`[Torch] VM opened`）。
- *CRASH* — アプリのプロセス名を持つ新しい`.ips`レポート、または既知の
  クラッシュ署名が出力に現れた。
- *RUBY_ERROR* — 起動時にRubyのバックトレースが出た。この場合VMは開いたまま
  なので、そうでなければ期待行が出てしまい見逃す。

runの結果が割れた場合、タスクはNON-DETERMINISTICとしてabortします。ビルドの
外側の何かが結果に影響しているということです。生ログは`build/observe/`に落ち、
最初のOK runはgoldenファイルとして保存され、以後のrunがdiff対象にします。

SimulatorはUDID（`SIM_UDID`。既定値はRakefile内）で固定し、コンテナ状態をrun
間で統制された変数に保ちます。消去や再作成はしないでください。そのUDIDが手元に
無い場合は最初に利用可能なiPhone Simulatorが使われ、警告が出ます。

**`rake determinism:ios:repl`**は同じ問いをビルド側から攻めます。`ios-repl`の
`libmruby.a`をクリーンビルドで2回作り、アーカイブから展開したメンバのハッシュを
比較します（コードに関係なく毎回変わる`ar`ヘッダのタイムスタンプは無視）。
ハッシュが一致すれば、同じ入力が本当に同じオブジェクトを産んだということです。

## 全体の組み立て

```
examples/ios/<name>/Sources/*.swift          SwiftUI
        │  bridging header
        ▼
bridge/picoruby_bridge.c                     C ブリッジ
        │
        ▼
Vendor/lib/libmruby.a                        prism コンパイラ + mruby VM。
                                             build_config/r2p2-picoruby-<target>.rb が
                                             vendor/picoruby からクロスビルド
```

ブリッジは2つの形を提供し、各exampleはどちらか一方を使います。

- `repl_eval(src)`は新しいVMを開き、`src`をコンパイル・実行し、捕捉した
  stdoutとstderr（コンパイル診断と未捕捉例外のバックトレースを含む）をmalloc済み
  文字列で返します。解放は呼び出し側の責務です。`repl`exampleがこれを使い、
  評価ごとにクリーンなVMが1つ立ちます。
- `vm_open` / `vm_call` / `vm_close`は永続VMを持ちます。`vm_open`が同梱の
  `app.rb`をコンパイル・実行し、`app.rb`はRubyのグローバル`$app`を代入します。
  `vm_call`はそのオブジェクトのメソッドを呼び、そのメソッドがprintした内容を
  返します。他のexampleはすべてこちらです。各`vm_call`はmrubyのtask内で
  dispatchされるため、RubyコードはVM自身のイベントキューでblockできます。VMに
  触れるのは生存期間を通じて単一のownerスレッドだけです。

`bridge/task_hal_ios.c`はiOSとwatchOS向けのmruby task scheduler HALです。この
2つには使えるSIGALRMタイマーが無いのでpollingで代替します。Rubyの`sleep_ms`が
実機で実時間だけ待つのは、これのおかげです。

gemは静的リンクされます。ビルド設定が挙げたmrbgemはすべて`libmruby.a`に
コンパイルされ、実行時に取得されるものはありません。`picoruby-*`gemのC側はVMが
開くときに登録されますが、Ruby側はpicogemとして`require`時にロードされます。
BLE系exampleの`app.rb`が`BLE`をサブクラス化する前に`require "ble"`から始まるのは
そのためです。あるクラスをexampleで使えるようにするには、そのgemをそのexampleの
ビルド設定に足します。

### gem集合は2種類

**フルREPL** — `mruby-posix` + `core` + `stdlib` + `shell`のgembox。Rubyの表面を
すべて使えますが、リンクは大きくなります。`repl`と`networking`が使います
（socket / mbedtls / rngの各gemがPOSIX前提の分岐を持つため）。

**縮小版** — `conf.picoruby` + `mruby-compiler` + `picoruby-machine`のみで
gemboxなし。`puts`と`print`のあるコアRubyですが`stdlib`が無く、`defined?`・
`String#ord`・`String#%`は使えません。`virtual-peripheral`、`iphone-torch`、
`stackchan`、`tilt-synth`、watchOS exampleが使います。

ビルド設定はexampleごとに独立しているので、縮小版で足りないexampleは自分の設定に
gemを足します。`virtual-peripheral`と`stackchan`で`Array#pack`が使えて
`iphone-torch`では使えないのはそのためです。exampleに新しいRubyを載せるときは、
実機で頼る前に`rake smoke`のホストビルドで試してください。

### ホットなメソッドを事前コンパイルする

ここまではすべてインタプリタ実行です。起動時にprismが`app.rb`をコンパイルし、VMが
それを走らせます。割に合うだけホットなメソッドは、代わりにビルド前にネイティブ
コードへコンパイルできます。matzのspinel AOTコンパイラでコンパイルし、
[suppify](https://github.com/bash0C7/suppify)でPicoRubyのmrbgemに包んで、他のgemと
同じようにリンクします。

インタプリタ版はA/Bのベースラインとしてツリーに残り、`app.rb`はどちらでも同じ
メソッド名で呼びます。full-mruby VMでは生成されたgemがVMを開くときに
`kernel_module`へ登録されるので、足すべき`require`はありません。

[repl example](examples/ios/repl/README_jp.md#aotとインタプリタ)に実証済みの
ベンチカーネルが`aot-kernel/`以下に入っています。物理のiPhone 16eでは、1回の
呼び出しに十分な計算を寄せて境界を越えるコストが薄まると、ネイティブ版がインタ
プリタの約50倍に達します。これを自分のメソッドに適用する手順は`aot-embed` skill
（`.claude/skills/aot-embed/`）にあります。

## vendorの取得元

既定の取得元は[bash0C7/picoruby](https://github.com/bash0C7/picoruby)の
`port-darwin`ブランチです。upstream masterに、darwin port（ble / rng / mbedtls /
io-console / machine / socket）と`hal-io-darwin`を加えたものです。
`hal-io-darwin`は、`fork`と`exec`を禁じるwatchOS SDK向けに`mruby-io`のposix HAL
を差し替える外部HAL providerです。

upstreamの`picoruby/picoruby` masterにはこれらのportがありません。
`PICORUBY_REF`をそちらへ向けると、darwin portを先に選ぶexampleがすべて壊れます。
`networking`（TLSがiOSに無いOpenSSLを要求する）、`virtual-peripheral`、
`stackchan`、そしてwatchOSビルドです。portを持つfork / branchであれば何でも
構いません。`PICORUBY_REF`はvendorツリー全体を差し替えるものであり、特定のrefに
固定する規則はここにはありません。

## ディレクトリ構成

```
R2P2-darwin/
  Rakefile               check / setup / refresh / smoke / ios:<example>:* /
                         watchos:led:* / determinism:* / clean / clobber
  rakelib/macos.rake     macos:check / macos:build / macos:run / macos:single
  build_config/
    r2p2-picoruby-ios-<example>-{sim,device}.rb    example ごとの iOS クロスビルド
    r2p2-picoruby-watchos-{sim,device}.rb          watchOS クロスビルド
    recompile_arm64_32.rb                          Apple Watch 向け arm64_32 再アーカイブ
    r2p2-picoruby-darwin{,-ble,-single}.rb         macOS ホストビルド
    r2p2-picoruby-host.rb                          `rake smoke` が使うホストビルド
    r2p2-picoruby-ios-{rng,mbedtls,io-console}-sim.rb
                                                   単一 gem の darwin port 検証用
                                                   （rake タスク無し。下記参照）
    r2p2-stackchan-pc.rb                           stackchan-picoruby の PC 側ホストビルド
  bridge/                picoruby_bridge.{c,h}, task_hal_ios.c, smoke_test.c
  examples/
    ios/<name>/          SwiftUI アプリ + app.rb（必要なら example 専用 gem）
    watchos/led-toggle/  watchOS example
    macos/ls/            rake macos:single のデモスクリプト
  vendor/picoruby/       rake setup が取得（gitignore 対象）
  build/                 全ビルド出力、MRUBY_BUILD_DIR（gitignore 対象）
```

単一gemの検証用設定3つは、素のVMにちょうど1つのgemを足してクロスビルドし、その
gemのdarwin portがiOS SDK向けに単独でコンパイル・リンクできることを確認します。
rakeタスクは持たないので、各`:lib`タスクと同じやり方でvendorツリーを直接叩きます。

```sh
cd vendor/picoruby
MRUBY_BUILD_DIR=../../build \
MRUBY_CONFIG=$(cd ../.. && pwd)/build_config/r2p2-picoruby-ios-rng-sim.rb \
  rake
```

## 検証済み環境

| | 検証したバージョン |
|---|---|
| macOS | 26.5 |
| Xcode | 26.5 (17F42) |
| Ruby | 4.0.5 |

実機ビルドは物理iPhone（`arm64`）とApple Watch（`arm64_32`）に対して、無料の
Apple ID Personal Teamで署名して実行を確認しています。

## ライセンス

[MIT](LICENSE)
