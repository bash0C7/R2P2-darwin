# `picoruby-iphone-torch` example — design

## 目的

iPhone のフラッシュライト（torch）を on/off するだけの最小 example。組込みの「L チカ」の
iPhone 版。Ruby（PicoRuby VM 上の app.rb）が、`picoruby-iphone-torch` gem の Darwin port
経由で `AVCaptureDevice` の torch を駆動する。R2P2-iOS の掲げる ports モデル
（interface は `include/*.h`、arch 依存実装は `ports/<arch>/`、Apple framework は port が
Swift backend を介して駆動）を、最小の題材で体現することがこの example の存在意義。

抽象は **iPhone シリーズの torch 制御に限定**。汎用 LED でも cross-arch でもない。単一 port
（darwin/iOS）の gem なので「全 arch 同一 interface」原則は適用対象外。レベル制御は対象外
（on/off のみ）。

## 配置

gem は example のサブディレクトリに新規作成する（picoruby-ble と違い vendor/picoruby 内では
なく、この repo 内のローカル gem）。

```
examples/iphone-torch/
  picoruby-iphone-torch/          # 新規ローカル gem（案 A: フル port 構造）
    mrbgem.rake
    include/torch.h               # port ABI（全 port 共通の宣言）
    src/torch.c                   # VM 振り分け: #include "mruby/torch.c"
    src/mruby/torch.c             # mruby C ext: Torch クラス定義、ABI を呼ぶ
    ports/darwin/torch.c          # TORCH_* を Swift ptorch_* へ委譲
    ports/darwin/ext/             # Swift Package PicoTorchDarwin（AVCaptureDevice）
      Package.swift
      Sources/PicoTorchDarwin/PicoTorchExports.swift
  app.rb                          # $app = TorchApp.new（dispatcher）
  Sources/                        # SwiftUI アプリ（ON / OFF ボタン）
  project.yml                     # xcodegen 用
  README.md

build_config/
  r2p2-picoruby-ios-torch-sim.rb
  r2p2-picoruby-ios-torch-device.rb
```

## アーキテクチャ

torch は on/off の fire-and-forget。vperiph の周期 `tick` timer は**不要**。ボタン押下が直接
`vm_call` を呼ぶ。

```
[SwiftUI ON/OFF ボタン]
  --vm_call(vm, "on"/"off", "")-->  $app(Ruby, TorchApp)  -->  Torch#on / #off
    --> src/mruby/torch.c  (mrb_funcall 先の C メソッド)
    --> TORCH_set(true/false)            [include/torch.h の port ABI]
    --> ports/darwin/torch.c              [Darwin port]
    --> ptorch_set(1/0)                   [Swift @_cdecl]
    --> AVCaptureDevice.torchMode = .on/.off
```

VM ライフサイクル: `vm_open(app.rb)` で boot し `$app = TorchApp.new` を定義。各ボタンが
`vm_call(vm, "on", "")` / `vm_call(vm, "off", "")` を呼ぶ。timer なし。mruby は single-thread
なので vm_open / vm_call / vm_close は VMExecutor の serial queue 上の 1 スレッドで実行
（vperiph と同じ規律）。

## gem 内部レイヤリング（案 A: picoruby-ble と同型のフル port 構造）

picoruby の gem ビルドは `src/*.c`（自動）、`mrblib/*.rb`（自動）、`conf.ports :darwin` で
選ばれた `ports/darwin/*.c`（`effective_ports` 経由で自動）をコンパイルする。`include/*.h` は
gem 間用ヘッダ。

- **`include/torch.h`** — port ABI（全 port 共通の宣言。darwin 専用 gem だが、ports モデルを
  体現するため境界を残す）:
  ```c
  #include <stdbool.h>
  bool TORCH_set(bool on);     /* torch を点灯/消灯。成功で true */
  bool TORCH_available(void);  /* この端末に torch があるか */
  ```

- **`src/torch.c`** — VM 振り分け（picoruby-ble の src/ble.c と同型）:
  ```c
  #if defined(PICORB_VM_MRUBY)
  #include "mruby/torch.c"
  #elif defined(PICORB_VM_MRUBYC)
  #include "mrubyc/torch.c"
  #endif
  ```
  この example は mruby VM（mruby-compiler2 / picoruby-mruby）を使うので mrubyc 版は省略可
  （`#elif` ブロックを置かない）。

- **`src/mruby/torch.c`** — mruby C 拡張。`Torch` クラスを定義し、メソッドを ABI に bind:
  - `Torch#on`  → `TORCH_set(true)` を呼び結果（成功/不可）を返す
  - `Torch#off` → `TORCH_set(false)`
  - `Torch#available?` → `TORCH_available()`
  - gem init で `mrb_define_class` / `mrb_define_method`。

  `Torch` のメソッドは C 定義（src/mruby/torch.c）とし、`mrblib/` は置かない。Ruby から見た
  `class Torch` の面は C 拡張が登録する。

- **`ports/darwin/torch.c`** — `TORCH_set` / `TORCH_available` を実装し Swift `ptorch_*` へ委譲。
  生成 `-Swift.h` には依存せず、2 つの extern を自前宣言する:
  ```c
  extern int ptorch_set(int on);
  extern int ptorch_available(void);
  ```
  → swift build をクロスビルド中に走らせない（build_config の `darwin? => false` monkeypatch
  すら不要）。

- **`mrbgem.rake`** — spec（name / license / author / summary）のみ。`add_dependency` なし
  （mbedtls / cyw43 等を一切引かないので、vperiph 必要だった依存 strip も不要）。

## Swift backend（`ports/darwin/ext/`）

`PicoBLEDarwin` と同型の dynamic library product `PicoTorchDarwin`。torch のみ。

```swift
import AVFoundation

@_cdecl("ptorch_set")
public func ptorch_set(_ on: Int32) -> Int32 {
  guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return 0 }
  do {
    try device.lockForConfiguration()
    device.torchMode = (on != 0) ? .on : .off
    device.unlockForConfiguration()
    return 1
  } catch { return 0 }
}

@_cdecl("ptorch_available")
public func ptorch_available() -> Int32 {
  (AVCaptureDevice.default(for: .video)?.hasTorch ?? false) ? 1 : 0
}
```

- capture session を起動しないので**カメラ権限不要**。Info.plist のプライバシキーは不要
  （BLE example より簡素）。
- `Package.swift`: product `PicoTorchDarwin`（dynamic library）、platform iOS、AVFoundation は
  system framework。

## ビルド / リンク モデル（vperiph と同一）

- クロスビルド（`libmruby.a`）は `ports/darwin/torch.c` を含む。これは `ptorch_*` を未解決
  シンボルとして持つ（.a では未定義。想定どおり）。
- Swift backend（`PicoTorchDarwin`）は **app link 時**に project.yml の package 依存
  （embed: true）として Xcode が iOS 向けにビルドし、`ptorch_*` を解決する。
- `darwin?` monkeypatch 不要（gem の mrbgem.rake は `build.darwin?` を参照しない）。

## build_config

`build_config/r2p2-picoruby-ios-torch-sim.rb` / `-device.rb`。base の最小 VM
（`r2p2-picoruby-ios-{sim,device}.rb` と同じ ABI defines・gem set）に以下を足すだけ:

- `conf.gem` でローカル gem ディレクトリ（`examples/iphone-torch/picoruby-iphone-torch`）を追加。
- `conf.ports :darwin`（`ports/darwin/torch.c` を選択）。
- ext の include path は port C が `-Swift.h` を使わないので不要。

vperiph と違い、mbedtls / cyw43 の依存 strip も `darwin?` monkeypatch も**不要**。

## project.yml

vperiph を雛形に:

- target `Torch`（application, iOS 17.0）。
- package `PicoTorchDarwin`: `path: examples/iphone-torch/picoruby-iphone-torch/ports/darwin/ext`、
  dependency に `embed: true`。
- sources: `Sources`, `app.rb`（buildPhase: resources）, `../../bridge`（picoruby_bridge.c/.h,
  task_hal_ios.c）。
- ABI defines（vperiph と同一、memory「iOS ABI defines build-wide trap」のとおり必須）:
  `MRB_CONSTRAINED_BASELINE_PROFILE=1`, `MRB_HEAP_PAGE_SIZE=128`, `PICORB_PLATFORM_DARWIN`,
  `MRB_INT64`, `MRB_NO_BOXING`, `MRB_UTF8_STRING`, `PICORB_ALLOC_ESTALLOC`,
  `PICORB_ALLOC_ALIGN=8`, `MRB_TICK_UNIT=4`, `MRB_TIMESLICE_TICK_COUNT=3`,
  `MRB_USE_TASK_SCHEDULER=1`, `MRB_USE_VM_SWITCH_DISPATCH=1`。
- HEADER_SEARCH_PATHS は torch ビルドディレクトリ（`build/ios-torch-{sim,device}/include`）を含む。
- bridging header, LIBRARY_SEARCH_PATHS（Vendor/lib）, `-lmruby`。
- **Info.plist のカメラ権限キーは不要**（torch のみ）。
- bundle id `com.bash0c7.picoruby.Torch`、`DEVELOPMENT_TEAM SM5792D355`、`TARGETED_DEVICE_FAMILY "1,2"`。

## app.rb と UI

- **`app.rb`**: gem が `Torch` を提供。app は dispatcher を定義:
  ```ruby
  class TorchApp
    def initialize; @torch = Torch.new; @log = []; ...; end
    def on(arg = nil);  ... @torch.on  ...; flush_log; end
    def off(arg = nil); ... @torch.off ...; flush_log; end
  end
  $app = TorchApp.new
  ```
  on/off 時に状態ログ（"torch on" / "torch unavailable (simulator)" 等）を print し、
  `vm_call` の戻り（captured stdout）として Swift に返す。
- **`ContentView`**: `ON` ボタンと `OFF` ボタンの 2 つ（ご要望どおり。レベル制御・トグル無し）
  ＋ 状態テキスト / ログ表示。Swift には torch ロジックを一切置かない。ボタン tap →
  `VMExecutor` 経由で `vm_call(vm, "on"/"off", "")`。
- **`VMExecutor`**: vperiph から timer を除いた版。`vm_open` で boot、`call(method:)` で
  serial queue 上から `vm_call`。

## エッジ / 検証

- **Simulator には torch が無い**: `AVCaptureDevice.default(for: .video)` が nil → `ptorch_*` は
  0 を返す。app.rb は "torch unavailable" をログし**クラッシュしない**。実機（device config）
  でのみ実際に点灯。sim build は load / VM 健全性確認用に残す（vperiph と対称）。
- **reduced VM の言語面**（memory「Reduced PicoRuby VM language surface」）: `Torch` / `TorchApp`
  は `defined?` / `Array#pack` 等を使わない。実装後、host libmruby に対し bundled Ruby を probe
  して on-device 前に健全性確認する。

## テスト / 受け入れ

1. `rake check` 相当の iOS build 前提が満たされること。
2. sim build がリンク成功し、起動して VM が boot、ON/OFF ボタンが "torch unavailable
   (simulator)" をログすること（クラッシュ無し）。
3. device build がリンク成功し、実機で ON ボタンで torch 点灯・OFF で消灯すること
   （実機 + 物理確認は人手）。
4. base の REPL / vperiph の app link が壊れていないこと（example-scoped の確認）。

## スコープ外（YAGNI）

- torch のレベル（明るさ）制御。
- トグル 1 ボタン UI（ON / OFF の 2 ボタンに固定）。
- rp2040 / esp32 port（include ABI は将来の余地として残すが、本 example では実装しない）。
- カメラ撮影・プレビュー・session 管理。
