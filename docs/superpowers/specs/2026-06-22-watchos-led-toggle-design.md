# watchOS LED Toggle — Design Spec

## Goal

`examples/watch-led-toggle/` として追加する PicoRuby 駆動の Apple Watch アプリ。
画面中央に 🔴 を表示し、タップするたびに 🔵 ↔ 🔴 をトグルする Hello World。
実機: Series 8 / watchOS 26.5。

## Architecture

darwin port（watchOS も Darwin ARM64）を watchsimulator / watchos SDK に向けるだけで
PicoRuby VM をビルドできる。新規 port は不要。

## Directory Layout

```
examples/watch-led-toggle/
├── app.rb
├── project.yml
├── Sources/
│   ├── App.swift
│   ├── ContentView.swift
│   ├── VMExecutor.swift
│   └── WatchLEDToggle-Bridging-Header.h
└── Vendor/lib/               # libmruby.a (watchOS sim / device)

build_config/
├── r2p2-picoruby-watchos-sim.rb
└── r2p2-picoruby-watchos-device.rb
```

Rakefile に `ios:watch:lib / :gen / :build` を追加（`ios:vperiph:*` と同形）。

## Ruby (app.rb)

```ruby
@state = "red"

def tick
  @state
end

def toggle
  @state = @state == "red" ? "blue" : "red"
  @state
end
```

- `tick`: 現在の色を返す。副作用なし。Swift が 100ms 毎に呼ぶ。
- `toggle`: 状態を反転して新しい色を返す。タップ時に Swift が呼ぶ。
- VM は serial DispatchQueue で動くため tick / toggle 間の排他制御は不要。

## Swift / SwiftUI Layer

### VMExecutor

virtual-peripheral の `VMExecutor` を基礎に、`toggle()` メソッドを追加する。

```
start(bootSource:onColor:)  — VM を起動し 100ms tick を開始
toggle()                    — queue 上で vm_call("toggle","") を呼び、結果を onColor へ
```

tick と toggle はどちらも同じ serial queue で直列実行されるため mruby の単一スレッド制約を守る。

### ContentView

```swift
Text(color == "red" ? "🔴" : "🔵")
    .font(.system(size: 80))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onTapGesture { VMExecutor.shared.toggle() }
    .onAppear { boot() }
```

SwiftUI 状態は `@State private var color = "red"` 1 変数のみ。

## Build Config

`r2p2-picoruby-watchos-sim.rb`:
- SDK: `xcrun --sdk watchsimulator`
- flags: `-arch arm64 -mwatchos-simulator-version-min=#{watchos_min}`
- `watchos_min = ENV["WATCHOS_MIN"] || "11.0"`
- defines: iOS sim 版と同一（`PICORB_PLATFORM_DARWIN` 等）

`r2p2-picoruby-watchos-device.rb`:
- SDK: `xcrun --sdk watchos`
- flags: `-arch arm64 -mwatchos-version-min=#{watchos_min}`

## project.yml

- `platform: watchOS`
- `deploymentTarget.watchOS: "11.0"` (Series 8 が動かせる最低限)
- `TARGETED_DEVICE_FAMILY: "4"` (Watch のみ)
- BLE 用 Info.plist キーは不要
- `DEVELOPMENT_TEAM: SM5792D355`（既存例と同じ Personal Team）

## Rakefile Tasks

```
ios:watch:lib    — libmruby.a を watchOS Simulator 向けにビルド
ios:watch:gen    — xcodegen でプロジェクト生成
ios:watch:build  — xcodebuild -destination watchsimulator でビルド
```

## Risk

`task_hal_ios.c`（shared bridge）が iOS 固有の API を使っている場合、watchOS SDK でのコンパイルに失敗する可能性がある。その際は `task_hal_watchos.c` を `bridge/` に追加して差し替える。

## Out of Scope

- iPhone companion app / WatchConnectivity
- BLE、センサー、クラウン操作
- watchOS device 向けの署名・開発者モード設定（Hello World の範囲外）
