# watchOS Stack-chan Controller Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `examples/watchos/stackchan/` を追加し、Apple Watch単体で動くPicoRuby駆動のStack-chan操作アプリ（顔トグル / ランダムLED点滅トグル / 首のスイープ）をwatchOS Simulatorで起動できる状態にする。

**Architecture:** watch上の専用Threadが持つPicoRuby VMが `app.rb` を実行し、picoruby-bleのcentralロールでStack-chanのNordic UART Serviceへ直接ASCIIフレームを書く。SwiftUIはVMへクロージャをpostするだけで `vm_*` を直接呼ばない。watchOSは `CBPeripheralManager` を持たないので、fork側でpicoruby-bleのDarwin portからperipheralロールをwatchOS向けにコンパイル対象外にする。

**Tech Stack:** PicoRuby（prismコンパイラ内蔵） / picoruby-ble Darwin port（CoreBluetooth） / SwiftUI（watchOS 26） / XcodeGen / Rake / mruby CrossBuild

**Spec:** `docs/superpowers/specs/2026-09-06-watchos-stackchan-design.md`

## Global Constraints

- **実機は未接続。** 完了ラインは `rake watchos:stackchan:run`（watchOS Simulator上でVMがbootしUIが操作できること）。実機Apple Watch + 実Stack-chanでの挙動確認はこの計画のスコープ外。BLEはSimulatorでは繋がらず、Connectはスキャンのタイムアウトで失敗するのが正しい挙動。
- **`vendor/picoruby` は生成物。commitしない。** 本repoからupstreamへのpush / PRもしない。
- **fork（`bash0C7/picoruby`）の編集は `~/dev/src/github.com/bash0C7/picoruby` の `port-darwin` worktreeで行い、`port-darwin` へ直接commitする。** topic branchを作らない。**pushはuser承認必須** — この計画の中でpushしない。
- 未pushのfork commitを本repoへ流し込むコマンド:
  `PICORUBY_REPO=/Users/bash/dev/src/github.com/bash0C7/picoruby PICORUBY_REF=port-darwin rake refresh`
- **picoruby-bleの `picoruby-mbedtls` / `picoruby-rng` 依存を外さない。** `ble.rb` がbootで `require 'mbedtls'` し、GATT database hashが `MbedTLS::CMAC` を使う。外すとBLEのRuby層が丸ごと未ロードになり `BLE.new` が `wrong number of arguments` で落ちる。
- **example固有のgemはexample専用build_configに置く。** BLEと `mruby-random` は `r2p2-picoruby-watchos-stackchan-*.rb` にのみ入れる。既存の `r2p2-picoruby-watchos-{sim,device}.rb` には足さない（led-toggleのリンクが壊れる）。
- **mruby task HALの6 entry（`mrb_hal_task_init` / `_final` / `_idle_cpu` / `_sleep_us`、`mrb_task_enable_irq` / `_disable_irq`）は `bridge/task_hal_ios.c` の所有物。** darwin portの `hal.c` に定義しない。
- **define parity。** `project.yml` の `GCC_PREPROCESSOR_DEFINITIONS` とbuild_configの `cc.defines` を一致させる。`MRB_BASELINE_PROFILE=1` はconfigに書かれず `picoruby-mruby` がbuild-wideに足すので、`project.yml` 側が追従する。
- **build_configのdefineを変えたら再build前に `rm -rf build/<target>`。** compile ruleは `.c` のmtimeしか見ないのでstaleな `.o` が再利用され、変更が黙って効かない。
- **左右の反転（`"left" => "R"` / `"right" => "L"`）はファームウェアの配線に合わせたload-bearingな仕様。直さない。**
- Xcode SDKは `WatchOS26.5.sdk` / `WatchSimulator26.5.sdk`。deployment targetは `project.yml` で `watchOS 26.0`、build_configの `WATCHOS_MIN` 既定は `11.0`（既存exampleと同じ）。
- Apple Team ID: `SM5792D355`。Bundle ID: `com.bash0c7.picoruby.WatchStackchan`。
- 作業branchは `feat/watchos-stackchan`（本repo）。

## VM ↔ Swift の出力contract

`vm_call(method, arg)` は `$app` のメソッドを呼び、captureしたstdout/stderrを返す。`BleLink` / `RealBleLink` の `write` はフレームを `print` するので、**captureされた出力にはフレームのechoが混ざる**。Swift側は行の接頭辞で状態行を拾う。

| method | arg | 状態行（出力のどこかの行） |
|---|---|---|
| `connect` | `""` | `Connected; RX value_handle bound`（成功時。iOS版と同一文字列） |
| `tick` | `""` | なし |
| `face_toggle` | `""` | `face:smile` または `face:joy` |
| `led_toggle` | `""` | `led:on:<color>` または `led:off` |
| `head_sweep` | `""` | `head:done` |

## File Structure

新規作成:

| ファイル | 責務 |
|---|---|
| `examples/watchos/stackchan/app.rb` | フレームエンコーダ + BLEトランスポート + dispatcher。アプリの挙動そのもの |
| `examples/watchos/stackchan/test_frames.rb` | host CRubyでのフレームbyte一致検証 |
| `examples/watchos/stackchan/project.yml` | XcodeGenのソース。ビルド設定・BLE package依存・Info.plistキー |
| `examples/watchos/stackchan/Sources/App.swift` | SwiftUIのエントリポイント |
| `examples/watchos/stackchan/Sources/ContentView.swift` | UI と VM出力のparse |
| `examples/watchos/stackchan/Sources/VMExecutor.swift` | VMを所有する専用Thread。全 `vm_*` の唯一の入口 |
| `examples/watchos/stackchan/Sources/WatchStackchan-Bridging-Header.h` | `picoruby_bridge.h` の取り込み |
| `examples/watchos/stackchan/README.md` / `README_jp.md` | example単体の手順 |
| `build_config/r2p2-picoruby-watchos-stackchan-sim.rb` | watchsimulator向けlibmruby.a（BLE込み） |
| `build_config/r2p2-picoruby-watchos-stackchan-device.rb` | watchos向けlibmruby.a（BLE込み、arm64_32） |

変更:

| ファイル | 変更内容 |
|---|---|
| `Rakefile` | `namespace :watchos` に `:stackchan` を追加 |
| `build_config/recompile_arm64_32.rb` | 決め打ちのbuild名/config名を引数化 |
| `README.md` / `README_jp.md`（repo直下） | example一覧とtask一覧に追記 |

fork（`~/dev/src/github.com/bash0C7/picoruby`、branch `port-darwin`）:

| ファイル | 変更内容 |
|---|---|
| `mrbgems/picoruby-ble/ports/darwin/ext/Package.swift` | `platforms` に `.watchOS(.v6)` |
| `mrbgems/picoruby-ble/ports/darwin/ext/Sources/PicoBLEDarwin/PicoBLEPeripheral.swift` | 全体を `#if !os(watchOS)` で囲う |
| `mrbgems/picoruby-ble/ports/darwin/ext/Sources/PicoBLEDarwin/PicoBLEExports.swift` | `pble_peripheral_*` をwatchOSではno-op stubに、`pble_drain_one` のpumpをwatchOSでskip |

---

### Task 1: fork — PicoBLEDarwin を watchOS でコンパイルできるようにする

**Files:**
- Modify: `~/dev/src/github.com/bash0C7/picoruby/mrbgems/picoruby-ble/ports/darwin/ext/Package.swift`
- Modify: `~/dev/src/github.com/bash0C7/picoruby/mrbgems/picoruby-ble/ports/darwin/ext/Sources/PicoBLEDarwin/PicoBLEPeripheral.swift`
- Modify: `~/dev/src/github.com/bash0C7/picoruby/mrbgems/picoruby-ble/ports/darwin/ext/Sources/PicoBLEDarwin/PicoBLEExports.swift`

**Interfaces:**
- Consumes: なし（最初のタスク）
- Produces: `PicoBLEDarwin` Swift packageがwatchOS向けにtypecheck・コンパイルできる状態。centralのCシンボル（`pble_central_init` / `pble_power_on` / `pble_power_off` / `pble_start_scan` / `pble_stop_scan` / `pble_connect` / `pble_discover_services` / `pble_discover_characteristics` / `pble_read_value` / `pble_discover_descriptors` / `pble_write_value` / `pble_write_descriptor` / `pble_drain_one`）と、peripheralのCシンボル（`pble_peripheral_init` / `pble_peripheral_power_on` / `pble_peripheral_power_off` / `pble_peripheral_advertise` / `pble_peripheral_stop_advertise` / `pble_peripheral_notify` / `pble_peripheral_request_can_send_now`）がwatchOSでも全てexportされる（peripheral側は中身がno-op）。

**背景:** watchOS SDKは `CBPeripheralManager` / `CBMutableService` / `CBMutableCharacteristic` の初期化子を `API_UNAVAILABLE(watchos, tvos)` と宣言している。`PicoBLEPeripheral.swift` はこれらを使うのでwatchOS向けにコンパイルできない。一方 `PicoBLECentral.swift` はwatchOSで問題なくtypecheckが通る。

`ble_peripheral.c` はwatchOSでもlibmruby.aに入り、`pble_peripheral_*` をexternとして参照する。exportごと消すとアプリのリンクが未解決シンボルで壊れるため、no-op stubは必須。

- [ ] **Step 1: fork worktreeの用意と、現状がwatchOSで壊れることの確認（RED）**

fork cloneが `port-darwin` にいることを確認する。

```bash
cd ~/dev/src/github.com/bash0C7/picoruby
git status --short --branch | head -3
```

`## port-darwin` 以外のbranchにいる場合は `git checkout port-darwin` する。

次に、typecheck用のmodule mapを作ってwatchOS SDKに対する型検査を走らせる。SwiftPMはC targetの `include/` からmodule mapを自動生成するが、`swiftc` を直接呼ぶときは自前で用意する必要がある。

```bash
EXT=~/dev/src/github.com/bash0C7/picoruby/mrbgems/picoruby-ble/ports/darwin/ext
MM=$(mktemp -d)/module.modulemap
cat > "$MM" <<EOF
module CBLEBridge {
  header "$EXT/Sources/CBLEBridge/include/CBLEBridge.h"
  export *
}
EOF
cd "$EXT" && xcrun --sdk watchsimulator swiftc -typecheck \
  -target arm64-apple-watchos26.0-simulator \
  -sdk "$(xcrun --sdk watchsimulator --show-sdk-path)" \
  -Xcc -fmodule-map-file="$MM" \
  Sources/PicoBLEDarwin/*.swift
```

Expected: FAIL。`PicoBLEPeripheral.swift` に少なくとも次の3種のエラーが出る。

```
Sources/PicoBLEDarwin/PicoBLEPeripheral.swift:70:37: error: 'init(delegate:queue:)' is unavailable in watchOS
Sources/PicoBLEDarwin/PicoBLEPeripheral.swift:293:17: error: 'init(type:primary:)' is unavailable in watchOS
Sources/PicoBLEDarwin/PicoBLEPeripheral.swift:298:18: error: 'init(type:properties:value:permissions:)' is unavailable in watchOS
```

`PicoBLECentral.swift` / `PicoBLEFifo.swift` / `PicoBLEPackets.swift` にエラーが出ないことを確認する。出た場合はこの計画の前提が崩れているので、先に進まずuserへ報告すること。

- [ ] **Step 2: `Package.swift` に watchOS プラットフォームを追加**

`platforms:` の行を変更する。

変更前:
```swift
  platforms: [.macOS(.v11), .iOS(.v13)],
```

変更後:
```swift
  // watchOS: centralロールのみ。CBPeripheralManager は watchOS で使えないため
  // PicoBLEPeripheral.swift は #if !os(watchOS) で除外し、その C 向け export は
  // no-op stub に落としてある（ble_peripheral.c が extern 参照を持つため）。
  platforms: [.macOS(.v11), .iOS(.v13), .watchOS(.v6)],
```

- [ ] **Step 3: `PicoBLEPeripheral.swift` を watchOS から除外**

ファイルの先頭（1行目、`import Foundation` の直前）に次を挿入する。

```swift
// CBPeripheralManager / CBMutableService / CBMutableCharacteristic は watchOS SDK が
// API_UNAVAILABLE(watchos, tvos) と宣言している。watchOS はこのポートを central
// ロールでしか使わないので、peripheral バックエンドごとコンパイル対象から外す。
// C 側 ble_peripheral.c は watchOS でもアーカイブに入り pble_peripheral_* を extern
// 参照するので、その export は PicoBLEExports.swift の no-op stub が受け持つ。
#if !os(watchOS)
```

ファイルの末尾（最終行の後）に次を追加する。

```swift
#endif  // !os(watchOS)
```

- [ ] **Step 4: `PicoBLEExports.swift` の peripheral export を分岐**

`// ---- peripheral / broadcaster roles (ports/darwin/ble.c, ble_peripheral.c) ----` のコメント行から、ファイル末尾の `pble_drain_one` の閉じ括弧までを、次のブロックで丸ごと置き換える。

```swift
// ---- peripheral / broadcaster roles (ports/darwin/ble.c, ble_peripheral.c) ----
//
// watchOS には CBPeripheralManager が無いため PBLEPeripheral は存在しない
// (PicoBLEPeripheral.swift 全体が #if !os(watchOS))。それでも ble_peripheral.c は
// watchOS のアーカイブに入り、これらのシンボルを extern 参照する。export を消すと
// アプリのリンクが未解決シンボルで壊れるので、watchOS では no-op stub を出す。

#if !os(watchOS)

/// `profile` is NULL for the broadcaster role, which advertises without a GATT database.
@c public func pble_peripheral_init(_ profile: UnsafePointer<UInt8>?) {
  PBLEPeripheral.shared.setup(profile: profile)
}

@c public func pble_peripheral_power_on() { PBLEPeripheral.shared.powerOn() }

@c public func pble_peripheral_power_off() { PBLEPeripheral.shared.powerOff() }

@c public func pble_peripheral_advertise(_ data: UnsafePointer<UInt8>, _ size: UInt16) {
  PBLEPeripheral.shared.advertise([UInt8](UnsafeBufferPointer(start: data, count: Int(size))))
}

@c public func pble_peripheral_stop_advertise() { PBLEPeripheral.shared.stopAdvertise() }

@c public func pble_peripheral_notify(_ attHandle: UInt16, _ data: UnsafePointer<UInt8>, _ size: UInt16) {
  PBLEPeripheral.shared.notify(attHandle: attHandle,
                               value: [UInt8](UnsafeBufferPointer(start: data, count: Int(size))))
}

@c public func pble_peripheral_request_can_send_now() {
  PBLEPeripheral.shared.requestCanSendNow()
}

/// VM-thread drain: copy one queued packet into `buf` (capacity `cap`); returns
/// the packet length, or 0 when empty or when an oversize packet was dropped.
/// Also pumps the peripheral backend (flush pending writes + refresh the read
/// cache) here, on the VM thread — the one place it may touch mruby. A no-op when
/// the peripheral backend is inactive (central/observer builds).
@c public func pble_drain_one(_ buf: UnsafeMutablePointer<UInt8>, _ cap: Int32) -> Int32 {
  PBLEPeripheral.shared.pump()
  return pbleSharedFifo.drainInto(buf, Int(cap))
}

#else  // os(watchOS)

@c public func pble_peripheral_init(_ profile: UnsafePointer<UInt8>?) {}

@c public func pble_peripheral_power_on() {}

@c public func pble_peripheral_power_off() {}

@c public func pble_peripheral_advertise(_ data: UnsafePointer<UInt8>, _ size: UInt16) {}

@c public func pble_peripheral_stop_advertise() {}

@c public func pble_peripheral_notify(_ attHandle: UInt16, _ data: UnsafePointer<UInt8>, _ size: UInt16) {}

@c public func pble_peripheral_request_can_send_now() {}

/// watchOS: peripheral バックエンドが存在しないので pump() は無い。central の
/// パケットを運ぶ FIFO の drain だけを行う。
@c public func pble_drain_one(_ buf: UnsafeMutablePointer<UInt8>, _ cap: Int32) -> Int32 {
  return pbleSharedFifo.drainInto(buf, Int(cap))
}

#endif  // !os(watchOS)
```

- [ ] **Step 5: watchOS Simulator SDK に対する typecheck が通ることを確認（GREEN）**

Step 1と同じコマンドを再実行する。

```bash
EXT=~/dev/src/github.com/bash0C7/picoruby/mrbgems/picoruby-ble/ports/darwin/ext
MM=$(mktemp -d)/module.modulemap
cat > "$MM" <<EOF
module CBLEBridge {
  header "$EXT/Sources/CBLEBridge/include/CBLEBridge.h"
  export *
}
EOF
cd "$EXT" && xcrun --sdk watchsimulator swiftc -typecheck \
  -target arm64-apple-watchos26.0-simulator \
  -sdk "$(xcrun --sdk watchsimulator --show-sdk-path)" \
  -Xcc -fmodule-map-file="$MM" \
  Sources/PicoBLEDarwin/*.swift && echo "WATCHOS SIM TYPECHECK OK"
```

Expected: PASS。`WATCHOS SIM TYPECHECK OK` が出る。

- [ ] **Step 6: watchOS device SDK に対する typecheck が通ることを確認**

```bash
EXT=~/dev/src/github.com/bash0C7/picoruby/mrbgems/picoruby-ble/ports/darwin/ext
MM=$(mktemp -d)/module.modulemap
cat > "$MM" <<EOF
module CBLEBridge {
  header "$EXT/Sources/CBLEBridge/include/CBLEBridge.h"
  export *
}
EOF
cd "$EXT" && xcrun --sdk watchos swiftc -typecheck \
  -target arm64_32-apple-watchos26.0 \
  -sdk "$(xcrun --sdk watchos --show-sdk-path)" \
  -Xcc -fmodule-map-file="$MM" \
  Sources/PicoBLEDarwin/*.swift && echo "WATCHOS DEVICE TYPECHECK OK"
```

Expected: PASS。`WATCHOS DEVICE TYPECHECK OK` が出る。

- [ ] **Step 7: iOS / macOS のリグレッションが無いことを確認**

`#if !os(watchOS)` の外側は従来どおりコンパイルされるはずだが、実際に確かめる。

```bash
EXT=~/dev/src/github.com/bash0C7/picoruby/mrbgems/picoruby-ble/ports/darwin/ext
MM=$(mktemp -d)/module.modulemap
cat > "$MM" <<EOF
module CBLEBridge {
  header "$EXT/Sources/CBLEBridge/include/CBLEBridge.h"
  export *
}
EOF
cd "$EXT"
xcrun --sdk iphoneos swiftc -typecheck -target arm64-apple-ios17.0 \
  -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" \
  -Xcc -fmodule-map-file="$MM" Sources/PicoBLEDarwin/*.swift && echo "IOS TYPECHECK OK"
swift build --package-path . 2>&1 | tail -5
```

Expected: `IOS TYPECHECK OK` が出て、`swift build`（macOS host）も成功する。

- [ ] **Step 8: fork に commit（pushはしない）**

```bash
cd ~/dev/src/github.com/bash0C7/picoruby
git add mrbgems/picoruby-ble/ports/darwin/ext/Package.swift \
        mrbgems/picoruby-ble/ports/darwin/ext/Sources/PicoBLEDarwin/PicoBLEPeripheral.swift \
        mrbgems/picoruby-ble/ports/darwin/ext/Sources/PicoBLEDarwin/PicoBLEExports.swift
git commit -F - <<'EOF'
ble/darwin: build the port for watchOS with the central role only

watchOS declares CBPeripheralManager, CBMutableService and
CBMutableCharacteristic initializers API_UNAVAILABLE, so the peripheral
backend cannot compile there. Wrap PicoBLEPeripheral.swift in
#if !os(watchOS) and add the platform to Package.swift.

ble_peripheral.c still enters the watchOS archive and references the
pble_peripheral_* symbols, so those exports become no-op stubs rather than
disappearing, and pble_drain_one skips the peripheral pump. iOS and macOS
builds are unchanged.
EOF
```

**pushしない。** userの承認を得るまでlocal commitのまま。

- [ ] **Step 9: 本repoへ流し込む**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
PICORUBY_REPO=/Users/bash/dev/src/github.com/bash0C7/picoruby \
PICORUBY_REF=port-darwin rake refresh
```

Expected: 成功。`vendor/picoruby` が更新される。

```bash
grep -n "watchOS" vendor/picoruby/mrbgems/picoruby-ble/ports/darwin/ext/Package.swift
```

Expected: `.watchOS(.v6)` を含む行が出る。

---

### Task 2: watchOS Simulator 向け build_config と `rake watchos:stackchan:lib`

**Files:**
- Create: `build_config/r2p2-picoruby-watchos-stackchan-sim.rb`
- Modify: `Rakefile`（`namespace :watchos` の末尾に `namespace :stackchan` を追加）

**Interfaces:**
- Consumes: Task 1が用意した、watchOS対応済みの `vendor/picoruby/mrbgems/picoruby-ble/ports/darwin/ext`
- Produces:
  - MRuby build名 `watchos-stackchan-sim`（出力は `build/watchos-stackchan-sim/`）
  - rake task `watchos:stackchan:lib` — `examples/watchos/stackchan/Vendor/{lib/libmruby.a,include/}` を生成する
  - Rakefile内のlocal変数 `ws_dir` / `ws_proj` / `ws_bundle` / `ws_vendor` / `ws_derived` / `ws_device_derived`（Task 4以降が同じ `namespace :stackchan` ブロック内で使う）

- [ ] **Step 1: build_config を書く**

Create `build_config/r2p2-picoruby-watchos-stackchan-sim.rb`:

```ruby
# watchOS Simulator (arm64) cross-build for the Stack-chan watch example:
# the bare picoruby VM/compiler PLUS picoruby-ble built with its Apple/Darwin
# (CoreBluetooth) port, in the central role only. EXAMPLE-SCOPED — BLE lives
# only in this config so the led-toggle example's libmruby.a keeps linking
# without it.
#
# Combines two existing configs:
#   * r2p2-picoruby-watchos-sim.rb — the watchsimulator SDK, the watchOS
#     version-min flag, and hal-io-darwin (watchOS forbids the fork/exec that
#     mruby-io's POSIX HAL uses for IO.popen).
#   * r2p2-picoruby-ios-stackchan-sim.rb — picoruby-ble with conf.ports :darwin,
#     the three mruby gems its mrblib needs, and the darwin? fallback.
#
# Plus mruby-random: app.rb's led_toggle picks a random colour with Kernel#rand,
# which this reduced gem set does not otherwise carry.
#
# task_hal_ios.c (shared bridge) is safe here despite its name: it uses only
# standard POSIX/Darwin APIs (clock_gettime, usleep) available on watchOS —
# it is the Darwin task HAL for every Apple platform in this repo.

sdk_path    = `xcrun --sdk watchsimulator --show-sdk-path`.strip
clang       = `xcrun --sdk watchsimulator --find clang`.strip
ar          = `xcrun --sdk watchsimulator --find ar`.strip
watchos_min = ENV["WATCHOS_MIN"] || "11.0"

# picoruby-ble's mrbgem.rake calls build.darwin?; on a picoruby tree whose
# build system lacks that predicate, loading the gem raises NoMethodError, so
# install a false fallback (guarded — a tree that defines darwin? keeps its
# own). false is the right answer for a watchOS static-.a cross-build: the
# gem's `if build.darwin?` branch is macOS-host glue (swift build of a macOS
# dylib). This config does the Darwin port selection itself (conf.ports
# :darwin) and adds the Swift-header include path. The Swift backend links
# into the APP target, not into libmruby.a; pble_* stay undefined in the .a,
# which is expected.
module MRuby
  class Build
    def darwin?
      false
    end unless method_defined?(:darwin?)
  end
end

MRuby::CrossBuild.new("watchos-stackchan-sim") do |conf|
  conf.toolchain :clang

  # The gcc/clang toolchain adds -lm by default, but libm is part of libSystem
  # on Apple platforms and the SDK marks it unavailable as a separate library.
  # Remove it to avoid link failure.
  conf.linker.libraries.delete("m")

  conf.cc.command       = clang
  conf.linker.command   = clang
  conf.archiver.command = ar
  conf.cc.host_command  = "clang"   # builds mrbc / compiler for the host

  conf.cc.flags << "-arch" << "arm64"
  conf.cc.flags << "-isysroot" << sdk_path
  conf.cc.flags << "-mwatchos-simulator-version-min=#{watchos_min}"

  conf.cc.defines << "MRB_TICK_UNIT=4"
  conf.cc.defines << "MRB_TIMESLICE_TICK_COUNT=3"
  conf.cc.defines << "PICORB_ALLOC_ALIGN=8"
  conf.cc.defines << "PICORB_ALLOC_ESTALLOC"
  conf.cc.defines << "PICORB_PLATFORM_POSIX"   # Darwin IS POSIX (XNU + BSD libc)
  conf.cc.defines << "PICORB_PLATFORM_DARWIN"  # ...and darwin (additive)
  conf.cc.defines << "MRB_INT64"
  conf.cc.defines << "MRB_NO_BOXING"
  conf.cc.defines << "MRB_UTF8_STRING"

  conf.picoruby

  conf.gem core: "mruby-compiler"

  # picoruby-ble's mrblib uses Array#pack / String#<< / sprintf. These live in
  # PicoRuby's stdlib gembox, which this bare-VM gem set omits, so pull the
  # three mruby gems in directly. mruby-random supplies Kernel#rand for
  # app.rb's led_toggle.
  mruby_mrbgems = "#{MRUBY_ROOT}/mrbgems/picoruby-mruby/lib/mruby/mrbgems"
  conf.gem gemdir: "#{mruby_mrbgems}/mruby-string-ext"
  conf.gem gemdir: "#{mruby_mrbgems}/mruby-pack"
  conf.gem gemdir: "#{mruby_mrbgems}/mruby-sprintf"
  conf.gem gemdir: "#{mruby_mrbgems}/mruby-random"

  # --- Stack-chan: picoruby-ble + CoreBluetooth Darwin port -----------------
  conf.ports :darwin, :posix
  # picoruby-machine carries the Estalloc heap glue the VM links against
  # (mrb_basic_alloc_func / mrb_open_with_custom_alloc) and the Machine module.
  # Upstream configs get it through gembox "core"; this reduced gem set adds it
  # explicitly. The :darwin port is what gets compiled (first match).
  conf.gem core: "picoruby-machine"
  # watchOS forbids fork/exec, which mruby-io's POSIX HAL uses for IO.popen.
  # hal-io-darwin is mruby's external HAL provider for mruby-io
  # (hal-<short>-<conf> naming): it replaces ports/posix/io_hal.c with the same
  # code minus spawning.
  conf.gem core: "hal-io-darwin"

  ble_gemdir = ENV["PICORUBY_BLE_GEMDIR"] ||
    File.expand_path("../vendor/picoruby/mrbgems/picoruby-ble", __dir__)

  # ports/darwin/*.c do `#include "PicoBLEDarwin-Swift.h"`, which lives in the
  # port's Swift package ext dir, not next to the .c. Put it on the include path.
  conf.cc.include_paths << "#{ble_gemdir}/ports/darwin/ext"

  # picoruby-ble's mrbgem.rake skips picoruby-cyw43 (rp2040 radio) when
  # build.darwin? is set. Its picoruby-mbedtls dependency stays: ble.rb does
  # `require 'mbedtls'` at boot and the GATT database hash uses MbedTLS::CMAC,
  # so stripping it leaves the BLE Ruby layer unloaded (BLE.new then fails with
  # "wrong number of arguments"). The mbedtls / rng darwin ports build for
  # watchOS (SecRandomCopyBytes entropy; the app links -framework Security).
  conf.gem ble_gemdir
end
```

- [ ] **Step 2: Rakefile に `namespace :stackchan` の骨格と `lib` task を追加**

`Rakefile` の `namespace :watchos do` ブロック内、`namespace :led do ... end` の **後ろ**（`namespace :watchos` の `end` の直前）に次を挿入する。

```ruby
  namespace :stackchan do
    ws_dir            = File.join(ROOT, "examples", "watchos", "stackchan")
    ws_proj           = File.join(ws_dir, "WatchStackchan.xcodeproj")
    ws_bundle         = "com.bash0c7.picoruby.WatchStackchan"
    ws_vendor         = File.join(ws_dir, "Vendor")
    ws_derived        = File.join(ROOT, "build", "watchos-stackchan-app")
    ws_device_derived = File.join(ROOT, "build", "watchos-stackchan-app-device")

    desc "Cross-build libmruby.a for watchOS Simulator (BLE) and stage under examples/watchos/stackchan/Vendor (env: WATCHOS_MIN)"
    task lib: :setup do
      stage_libmruby("r2p2-picoruby-watchos-stackchan-sim.rb", "watchos-stackchan-sim", ws_vendor)
    end
  end
```

- [ ] **Step 3: task が見えることを確認**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
rake -T watchos:stackchan
```

Expected: `rake watchos:stackchan:lib` の行が出る。

- [ ] **Step 4: libmruby.a をビルド（GREEN）**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
rm -rf build/watchos-stackchan-sim
rake watchos:stackchan:lib
```

Expected: 成功し、末尾に `Staged watchos-stackchan-sim libmruby.a + headers under .../examples/watchos/stackchan/Vendor` が出る。

長いビルドログが出るので、subagentに投げる場合はhaikuに「コマンドをverbatimで実行し、raw outputをそのまま返す」よう指示すること。

- [ ] **Step 5: 成果物を確認**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
lipo -info examples/watchos/stackchan/Vendor/lib/libmruby.a
nm examples/watchos/stackchan/Vendor/lib/libmruby.a 2>/dev/null | grep -c "U _pble_"
nm examples/watchos/stackchan/Vendor/lib/libmruby.a 2>/dev/null | grep -E "T _mrb_open_with_custom_alloc" | head -1
```

Expected:
- `lipo -info` が `arm64` を報告する
- `U _pble_` の数が1以上（Swift backendはアプリ側でリンクするので、.a では未定義のまま。これは想定どおり）
- `T _mrb_open_with_custom_alloc` が1行出る

- [ ] **Step 6: 既存の led-toggle が壊れていないことを確認**

新configは既存configに触っていないが、`rake refresh` で `vendor/picoruby` が更新されているので確かめる。

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
rm -rf build/watchos-sim
rake watchos:led:lib
lipo -info examples/watchos/led-toggle/Vendor/lib/libmruby.a
```

Expected: 成功し、`arm64` を報告する。

- [ ] **Step 7: Commit**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
git add build_config/r2p2-picoruby-watchos-stackchan-sim.rb Rakefile
git commit -F - <<'EOF'
build: watchOS Simulator cross-build config for the Stack-chan watch example

Merges the watchOS config (watchsimulator SDK, hal-io-darwin for the
fork/exec ban) with the iOS Stack-chan config (picoruby-ble on its Darwin
port, the three mruby gems its mrblib needs, the darwin? fallback), and
adds mruby-random for the random LED colour.

Example-scoped: BLE stays out of r2p2-picoruby-watchos-sim.rb so
led-toggle's libmruby.a keeps linking without it.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CoEkzNECosgLMsFZJfVrZ7
EOF
```

---

### Task 3: `app.rb` と `test_frames.rb`（host CRubyでのTDD）

**Files:**
- Create: `examples/watchos/stackchan/app.rb`
- Create: `examples/watchos/stackchan/test_frames.rb`

**Interfaces:**
- Consumes: なし（host CRubyだけで完結する。Task 1 / 2に依存しない）
- Produces:
  - グローバル `$app`（`Stackchan` のインスタンス）
  - `Stackchan#connect(arg=nil)` / `#tick(arg=nil)` / `#face_toggle(arg=nil)` / `#led_toggle(arg=nil)` / `#head_sweep(arg=nil)` — すべて1つのStringを受けてnilを返し、状態は `print` で出す
  - `Stackchan#ble` — 記録stub（host）または `RealBleLink`（device）
  - `Stackchan::LED_RANDOM_COLORS` — `["red", "green", "blue", "yellow", "cyan", "magenta"]`
  - `FrameCodec.encode_face(name)` / `.encode_led(color:, side:, mode:)` / `.encode_head(yaw_left:, yaw_right:, pitch_up:, time_ms:)` / `.parse_ack(frame)` / `.encode_pairs(pairs)`
  - `FrameCodec::FACE_INDICES` / `::LED_COLORS` / `::SIDE_TO_CHAR` / `::MODE_TO_CHAR` / `::ACK_OK` / `::ACK_ERROR`
  - `BleLink#sent` — 記録した全フレームのArray

- [ ] **Step 1: 失敗するテストを書く**

Create `examples/watchos/stackchan/test_frames.rb`:

```ruby
# Frame-encoding verification for the Stack-chan watch controller's bundled Ruby.
# Runs under host CRuby (`ruby test_frames.rb`): the encoders build plain
# strings, so CRuby and the reduced PicoRuby VM produce identical frames. This
# guards the wire format against regressions without a watch or a build.
#
# It loads app.rb (whose BleLink records frames instead of touching a radio) and
# asserts the exact bytes the firmware expects. Frame formats mirror the PC CLI's
# verified codec (stackchan-picoruby/pc/stackchan/test/test_ble_*.rb) and the iOS
# example's test_frames.rb.

require_relative "app"

# head_sweep paces its frames with msleep, which app.rb defines at top level.
# require_relative shares that top-level binding, so redefining msleep HERE
# (after the require, or app.rb's definition would win) makes head_sweep run
# instantly instead of sleeping 1.8 s.
def msleep(ms)
end

$failures = 0

def expect(label, actual, want)
  if actual == want
    puts "PASS #{label}: #{actual.inspect}"
  else
    $failures += 1
    puts "FAIL #{label}: got #{actual.inspect} want #{want.inspect}"
  end
end

def expect_include(label, actual, allowed)
  if allowed.include?(actual)
    puts "PASS #{label}: #{actual.inspect}"
  else
    $failures += 1
    puts "FAIL #{label}: got #{actual.inspect}, not one of #{allowed.inspect}"
  end
end

# Drive the dispatcher and read back what BleLink recorded.
def last_frame
  $app.ble.sent.last
end

# ---- face_toggle: smile <-> joy ------------------------------------------
# FACE_INDICES: smile => "1", joy => "2". The app boots holding "smile", so the
# FIRST toggle flips to joy.
$app.face_toggle
expect("face_toggle 1st -> joy", last_frame, "<F:2>\n")
$app.face_toggle
expect("face_toggle 2nd -> smile", last_frame, "<F:1>\n")
$app.face_toggle
expect("face_toggle 3rd -> joy", last_frame, "<F:2>\n")
$app.face_toggle
expect("face_toggle 4th -> smile", last_frame, "<F:1>\n")

# ---- led_toggle: random blink on, off ------------------------------------
# Every acceptable "on" frame, one per random colour.
on_frames = Stackchan::LED_RANDOM_COLORS.map do |c|
  rgb = FrameCodec::LED_COLORS[c]
  "<L:1,R:#{rgb[0]},G:#{rgb[1]},B:#{rgb[2]},S:B,M:b>\n"
end

$app.led_toggle
expect_include("led_toggle on is a blink frame in a random colour", last_frame, on_frames)
$app.led_toggle
expect("led_toggle off", last_frame, "<L:1,R:0,G:0,B:0,S:B,M:o>\n")
$app.led_toggle
expect_include("led_toggle on again", last_frame, on_frames)
$app.led_toggle
expect("led_toggle off again", last_frame, "<L:1,R:0,G:0,B:0,S:B,M:o>\n")

# The colour must actually vary. A `rand` that always returns 0 would pass the
# per-frame check above; 50 on-frames must show at least two distinct colours.
seen = {}
50.times do
  $app.led_toggle          # on
  seen[last_frame] = true
  $app.led_toggle          # off
end
if seen.keys.length >= 2
  puts "PASS led_toggle colour varies: #{seen.keys.length} distinct frames over 50 toggles"
else
  $failures += 1
  puts "FAIL led_toggle colour varies: only #{seen.keys.length} distinct frame(s) over 50 toggles"
end
# Every frame seen must still be a legal on-frame.
seen.keys.each_with_index do |f, i|
  expect_include("led_toggle sampled frame #{i}", f, on_frames)
end

# ---- head_sweep: left -> right -> up -> neutral --------------------------
before = $app.ble.sent.length
$app.head_sweep
swept = $app.ble.sent[before..-1]
expect("head_sweep emits 4 frames", swept.length, 4)
# "left" (StackChan's own perspective) is YL on the wire; "right" is YR.
expect("head_sweep 1 left",    swept[0], "<YL:60,T:500>\n")
expect("head_sweep 2 right",   swept[1], "<YR:60,T:500>\n")
expect("head_sweep 3 up",      swept[2], "<PU:40,T:500>\n")
expect("head_sweep 4 neutral", swept[3], "<YL:0,PU:0,T:400>\n")

# ---- the encoders themselves --------------------------------------------
expect("encode_face neutral", FrameCodec.encode_face("neutral"), "<F:0>\n")
expect("encode_face smile",   FrameCodec.encode_face("smile"),   "<F:1>\n")
expect("encode_face joy",     FrameCodec.encode_face("joy"),     "<F:2>\n")

expect("encode_led red solid both",
       FrameCodec.encode_led(color: "red", side: "both", mode: "solid"),
       "<L:1,R:255,G:0,B:0,S:B,M:s>\n")
# "left" (StackChan perspective) reverses to "R" on the wire; do not "fix" this.
expect("encode_led green blink left",
       FrameCodec.encode_led(color: "green", side: "left", mode: "blink"),
       "<L:1,R:0,G:255,B:0,S:R,M:b>\n")
expect("encode_led right reverses to L",
       FrameCodec.encode_led(color: "blue", side: "right", mode: "solid"),
       "<L:1,R:0,G:0,B:255,S:L,M:s>\n")

expect("encode_head left 50 500ms",
       FrameCodec.encode_head(yaw_left: 50, time_ms: 500), "<YL:50,T:500>\n")
expect("encode_head right 30 no-time",
       FrameCodec.encode_head(yaw_right: 30), "<YR:30>\n")
expect("encode_head up 20 250ms",
       FrameCodec.encode_head(pitch_up: 20, time_ms: 250), "<PU:20,T:250>\n")

expect("parse_ack ok",    FrameCodec.parse_ack("."), :ok)
expect("parse_ack error", FrameCodec.parse_ack("?"), :error)

# ---- the subset really is a subset --------------------------------------
# speak / torque / touch are out of scope for the watch. Their helpers must be
# gone, not merely unused, so the watch VM never carries dead weight.
%w[encode_text encode_audio_header chunk_audio_hex sanitize_text
   truncate_chars encode_torque parse_touch].each do |gone|
  if FrameCodec.respond_to?(gone)
    $failures += 1
    puts "FAIL FrameCodec.#{gone} should not exist in the watch subset"
  else
    puts "PASS FrameCodec.#{gone} absent"
  end
end
%w[face led head torque subtitle speak_audio].each do |gone|
  if $app.respond_to?(gone)
    $failures += 1
    puts "FAIL Stackchan##{gone} should not exist in the watch subset"
  else
    puts "PASS Stackchan##{gone} absent"
  end
end

if $failures.zero?
  puts "\nall passed"
else
  puts "\n#{$failures} FAILED"
  exit 1
end
```

- [ ] **Step 2: テストが失敗することを確認**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
ruby examples/watchos/stackchan/test_frames.rb
```

Expected: FAIL。`cannot load such file -- .../examples/watchos/stackchan/app` （`LoadError`）で落ちる。

- [ ] **Step 3: `app.rb` を書く**

Create `examples/watchos/stackchan/app.rb`:

```ruby
# Stack-chan watch controller — the bundled, fixed Ruby that the persistent
# PicoRuby VM runs on watchOS. It is not user-editable and not downloaded:
# PicoRuby is simply the implementation language for the app's own behavior
# (Guideline 2.5.2-free).
#
# A subset of examples/ios/stackchan/app.rb: three controls (a happy-face
# toggle, a random-colour LED blink toggle, and a one-shot head sweep back to
# neutral). Speak (subtitle + mu-law audio), torque, and touch events are out of
# scope for the watch.
#
# The frame encoders mirror the PC CLI's codec
# (stackchan-picoruby/pc/stackchan/lib/stackchan/ble/{frame_codec,face_table,
# led_color_table}.rb), with two differences for the reduced PicoRuby VM and the
# Swift->VM call seam:
#   1. No require_relative / module namespacing — the bundled app is one source.
#   2. String keys (not Symbols) because vm_call delivers a single String arg
#      from the Swift UI. The emitted frames are byte-identical to the PC codec.
#
# The wire frame format and the left/right reversal match the hardware and are
# load-bearing; do not "fix" SIDE_TO_CHAR.

module FrameCodec
  # API "left"/"right" are StackChan's own perspective (its hands); the firmware
  # wires them reversed, so "left" -> "R" and "right" -> "L" on the wire.
  SIDE_TO_CHAR = { "left" => "R", "right" => "L", "both" => "B" }
  MODE_TO_CHAR = { "solid" => "s", "blink" => "b", "breathing" => "p", "off" => "o" }
  FACE_INDICES = {
    "neutral" => "0", "smile" => "1", "joy" => "2",
    "surprised" => "3", "sad" => "4", "angry" => "5",
  }
  LED_COLORS = {
    "red" => [255, 0, 0], "green" => [0, 255, 0], "blue" => [0, 0, 255],
    "yellow" => [255, 255, 0], "cyan" => [0, 255, 255], "magenta" => [255, 0, 255],
    "white" => [255, 255, 255], "off" => [0, 0, 0],
  }

  ACK_OK    = "."
  ACK_ERROR = "?"

  def self.encode_pairs(pairs)
    "<" + pairs.map { |k, v| "#{k}:#{v}" }.join(",") + ">\n"
  end

  def self.encode_face(name)
    index = FACE_INDICES[name]
    raise ArgumentError, "unknown face: #{name}" unless index
    encode_pairs({ "F" => index })
  end

  # color: a named color string ("red"...). side: "left"/"right"/"both".
  # mode: "solid"/"blink"/"breathing"/"off".
  def self.encode_led(color:, side:, mode:)
    rgb = LED_COLORS[color]
    raise ArgumentError, "unknown color: #{color}" unless rgb
    side_char = SIDE_TO_CHAR[side]
    raise ArgumentError, "unknown side: #{side}" unless side_char
    mode_char = MODE_TO_CHAR[mode]
    raise ArgumentError, "unknown mode: #{mode}" unless mode_char
    encode_pairs({
      "L" => "1", "R" => rgb[0].to_s, "G" => rgb[1].to_s, "B" => rgb[2].to_s,
      "S" => side_char, "M" => mode_char,
    })
  end

  # Exactly one of yaw_left/yaw_right may be set (0..100); pitch_up optional
  # (0..100); time_ms optional. nil means "omit".
  def self.encode_head(yaw_left: nil, yaw_right: nil, pitch_up: nil, time_ms: nil)
    if !yaw_left.nil? && !yaw_right.nil?
      raise ArgumentError, "yaw_left and yaw_right are mutually exclusive"
    end
    if yaw_left.nil? && yaw_right.nil? && pitch_up.nil?
      raise ArgumentError, "encode_head needs one of yaw_left/yaw_right/pitch_up"
    end
    pairs = {}
    pairs["YL"] = yaw_left.to_s  unless yaw_left.nil?
    pairs["YR"] = yaw_right.to_s unless yaw_right.nil?
    pairs["PU"] = pitch_up.to_s  unless pitch_up.nil?
    pairs["T"]  = time_ms.to_s   if time_ms
    encode_pairs(pairs)
  end

  # frame[0,1] is safe on a bare 1-char ACK byte too.
  def self.parse_ack(frame)
    case frame[0, 1]
    when ACK_OK    then :ok
    when ACK_ERROR then :error
    else raise ArgumentError, "unknown ack frame: #{frame}"
    end
  end
end

# The BLE transport seam.
#
# `RealBleLink` (below) drives picoruby-ble's central role over the Darwin
# (CoreBluetooth) port: it scans for a Stack-chan advertising the Nordic UART
# Service (NUS), connects, discovers the RX characteristic value handle, and
# writes each ASCII frame to it. picoruby-ble is only present in the on-watch /
# Simulator VM, so this file guards every reference behind `BLE_AVAILABLE`:
# under host CRuby (test_frames.rb) BLE is absent and the recording `BleLink`
# stub is used instead, keeping the frame encoders verifiable without a radio.

# The Nordic UART Service and its RX (write) characteristic, the Stack-chan
# firmware's command channel.
NUS_SERVICE_UUID = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
NUS_RX_CHAR_UUID = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
# The discovered service/characteristic :uuid128 fields are 16 big-endian bytes
# (textual UUID order). bind_rx renders them to hex and matches against these
# dash-stripped constants (avoids calling BLE::Utils.uuid).
NUS_SERVICE_UUID128_HEX = "6e400001b5a3f393e0a9e50e24dcca9e"
NUS_RX_CHAR_UUID128_HEX = "6e400002b5a3f393e0a9e50e24dcca9e"
HEX_DIGITS = "0123456789abcdef"
# Substring matched against the advertised local name to pick the robot.
STACKCHAN_NAME = "StackChan"

# picoruby-ble's Ruby layer (BLE#initialize(role), scan, connect, ...) is a
# picogem: the C part defines the BLE constant at boot, the Ruby part loads on
# require (picoruby-require, pulled in by picoruby-machine). Host CRuby has no
# such gem, so LoadError means "no BLE here" and the stub below takes over.
begin
  require "ble"
rescue LoadError
  # host CRuby / a VM without picoruby-ble: BLE_AVAILABLE resolves below
end

# Is the picoruby-ble `BLE` class linked into this VM? The reduced PicoRuby VM
# (prism compiler) does not implement the `defined?` keyword — it compiles
# `defined?(BLE)` as a method call that raises at boot — so probe for the
# constant by referencing it and rescuing the NameError. True in the on-watch /
# Simulator VM (picoruby-ble linked); false under host CRuby (test_frames.rb),
# which then falls back to the recording `BleLink` stub.
BLE_AVAILABLE =
  begin
    BLE
    true
  rescue NameError
    false
  end

# sleep_ms comes from picoruby-machine in the watch VM; host CRuby has only
# sleep. Probe by calling (the reduced VM lacks the defined? keyword).
HAS_SLEEP_MS =
  begin
    sleep_ms(0)
    true
  rescue NameError, NoMethodError
    false
  end

def msleep(ms)
  if HAS_SLEEP_MS
    sleep_ms(ms)
  else
    sleep(ms / 1000.0)
  end
end

# Recording stub: used under host CRuby (no BLE) and as a graceful fallback so
# frames sent before a connection are not lost. Records and echoes frames.
class BleLink
  attr_reader :sent

  def initialize
    @sent = []
  end

  def connected?
    false
  end

  def connect
    print "(no BLE in this VM; frames are recorded)\n"
    false
  end

  def tick
    nil
  end

  def write(frame)
    @sent << frame
    # Echo so vm_call's stdout capture surfaces the frame during bring-up.
    print frame
    :ok
  end
end

if BLE_AVAILABLE
  # The picoruby-ble central. It overrides advertising_report_callback to connect
  # to the first peripheral whose advertised name contains STACKCHAN_NAME; after
  # connect the base class auto-discovers services/characteristics, leaving
  # @services populated and @state == :TC_IDLE.
  class StackchanCentral < BLE
    attr_reader :target

    def initialize
      super(:central)
      @target = nil
    end

    def advertising_report_callback(adv_report)
      return if @target
      if adv_report.name_include?(STACKCHAN_NAME)
        @target = adv_report
        print "Found Stack-chan; connecting\n"
        connect(adv_report)
      end
    end

    def conn_handle
      @conn_handle
    end
  end

  # Real transport over the Darwin CoreBluetooth backend.
  class RealBleLink
    def initialize
      @ble = StackchanCentral.new
      @rx_value_handle = nil
      @pending = []
    end

    def connected?
      !@rx_value_handle.nil? &&
        @ble.conn_handle != BLE::HCI_CON_HANDLE_INVALID
    end

    # Scan -> connect -> discover (all driven inside scan/connect's event loop) ->
    # bind the NUS RX value handle. Returns true once the RX handle is bound.
    def connect
      if connected?
        # Emit the same status line as a fresh success: the Swift UI derives
        # its connected/failed state from this exact string, so a silent early
        # return would flip the status to "connect failed" on a re-tap.
        print "Connected; RX value_handle bound\n"
        return true
      end
      print "Scanning for Stack-chan (NUS)\n"
      # On the Simulator no peripheral answers; scan simply times out.
      @ble.scan(timeout_ms: SCAN_TIMEOUT_MS)
      bind_rx
      if connected?
        print "Connected; RX value_handle bound\n"
        flush_pending
        true
      else
        print "No Stack-chan found. Check: robot powered on? Bluetooth on?\n"
        false
      end
    end

    # Pump BLE events (drains the Swift FIFO ~one packet per tick).
    def tick
      @ble.start(200) if connected?
      nil
    end

    def write(frame)
      unless connected?
        @pending << frame
        print frame
        return :pending
      end
      @ble.write_value_of_characteristic_without_response(
        @ble.conn_handle, @rx_value_handle, frame
      )
      print frame
      :ok
    end

    private

    # Walk discovered services for the NUS, then its RX characteristic. Match by
    # rendering each discovered :uuid128 (16 big-endian bytes) to hex.
    def bind_rx
      @ble.services.each do |service|
        next unless uuid128_hex(service[:uuid128]) == NUS_SERVICE_UUID128_HEX
        service[:characteristics].each do |chara|
          if uuid128_hex(chara[:uuid128]) == NUS_RX_CHAR_UUID128_HEX
            @rx_value_handle = chara[:value_handle]
            return
          end
        end
      end
    end

    # 16 bytes (big-endian as stored in :uuid128) -> lowercase hex String.
    def uuid128_hex(bytes)
      return "" unless bytes && bytes.bytesize == 16
      hex = ""
      i = 0
      while i < 16
        b = bytes.getbyte(i) || 0
        hex += HEX_DIGITS[(b >> 4), 1]
        hex += HEX_DIGITS[b & 0x0f, 1]
        i += 1
      end
      hex
    end

    def flush_pending
      until @pending.empty?
        write(@pending.shift)
      end
    end
  end
end

# watchOS suspends an app aggressively when the wrist drops, and the scan blocks
# the VM thread for its whole duration. Ten seconds is short enough to survive a
# glance and long enough to find a robot that is already advertising; the UI
# makes re-tapping Connect cheap.
SCAN_TIMEOUT_MS = 10000

# The dispatcher object the persistent-VM bridge calls. vm_call(method, arg)
# invokes one of these with a single String arg from the Swift UI.
#
# Every method prints a prefixed status line (face: / led: / head:) that the
# Swift UI parses out of the captured output. The BLE links echo each frame they
# write, so the status line is NOT the only line in the output — the UI matches
# on the prefix, not on the whole string.
class Stackchan
  # Colours led_toggle picks from. "white" and "off" are excluded: neither reads
  # as "the LED lit up in a random colour".
  LED_RANDOM_COLORS = ["red", "green", "blue", "yellow", "cyan", "magenta"]

  # The two happy faces the watch cycles between.
  FACE_A = "smile"
  FACE_B = "joy"

  # head_sweep's waypoints. Each frame asks the servo for a 500 ms move; the
  # pacing sleep is a little longer so one move finishes before the next starts.
  SWEEP_MAGNITUDE_YAW   = 60
  SWEEP_MAGNITUDE_PITCH = 40
  SWEEP_MOVE_MS         = 500
  SWEEP_PACE_MS         = 600
  SWEEP_NEUTRAL_MS      = 400

  attr_reader :ble

  def initialize(ble = nil)
    @ble = ble || (BLE_AVAILABLE ? RealBleLink.new : BleLink.new)
    @face_state = FACE_A
    @led_on = false
  end

  # Scan/connect/discover/bind the Stack-chan's NUS RX. arg is ignored (vm_call
  # always passes one String). Returns nothing; output is captured via print.
  # Expected failures (robot absent, BLE layer errors) become a one-line
  # message here; an uncaught exception would otherwise surface as a raw
  # backtrace in the log (the bridge's safety net for real bugs).
  def connect(arg = nil)
    begin
      @ble.connect
    rescue => e
      print "Connect failed: #{e.class}: #{e.message}\n"
    end
    nil
  end

  # Pump BLE events. Posted periodically by the Swift VM-owner thread.
  def tick(arg = nil)
    begin
      @ble.tick
    rescue => e
      print "tick error: #{e.class}: #{e.message}\n"
    end
    nil
  end

  # Flip between the two happy faces and send the frame. Prints "face:<name>".
  def face_toggle(arg = nil)
    @face_state = (@face_state == FACE_A ? FACE_B : FACE_A)
    @ble.write(FrameCodec.encode_face(@face_state))
    print "face:#{@face_state}\n"
    nil
  end

  # Toggle the LED. On: pick a random colour and blink both sides. Off: send the
  # off frame. Prints "led:on:<color>" or "led:off".
  def led_toggle(arg = nil)
    @led_on = !@led_on
    if @led_on
      color = LED_RANDOM_COLORS[rand(LED_RANDOM_COLORS.length)]
      @ble.write(FrameCodec.encode_led(color: color, side: "both", mode: "blink"))
      print "led:on:#{color}\n"
    else
      @ble.write(FrameCodec.encode_led(color: "off", side: "both", mode: "off"))
      print "led:off\n"
    end
    nil
  end

  # Sweep the head left, right, up, then back to neutral. Blocks the VM thread
  # for roughly SWEEP_PACE_MS * 3 by design; the UI keeps this single-flight.
  # Prints "head:done".
  def head_sweep(arg = nil)
    @ble.write(FrameCodec.encode_head(yaw_left: SWEEP_MAGNITUDE_YAW, time_ms: SWEEP_MOVE_MS))
    msleep(SWEEP_PACE_MS)
    @ble.write(FrameCodec.encode_head(yaw_right: SWEEP_MAGNITUDE_YAW, time_ms: SWEEP_MOVE_MS))
    msleep(SWEEP_PACE_MS)
    @ble.write(FrameCodec.encode_head(pitch_up: SWEEP_MAGNITUDE_PITCH, time_ms: SWEEP_MOVE_MS))
    msleep(SWEEP_PACE_MS)
    @ble.write(FrameCodec.encode_head(yaw_left: 0, pitch_up: 0, time_ms: SWEEP_NEUTRAL_MS))
    print "head:done\n"
    nil
  end
end

$app = Stackchan.new
```

- [ ] **Step 4: テストが通ることを確認**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
ruby examples/watchos/stackchan/test_frames.rb
```

Expected: PASS。最終行が `all passed`。exit statusは0。

`SCAN_TIMEOUT_MS` は `RealBleLink#connect` の中でしか参照されず、そのクラスは `BLE_AVAILABLE` がtrueのときしか定義されない。定数の定義がクラス定義より後ろにあるのは、Rubyの定数解決が呼び出し時に行われるため問題ない。host CRubyでは `RealBleLink` 自体が存在しないので触られない。

- [ ] **Step 5: 状態行が実際に出ていることを目で確認**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin/examples/watchos/stackchan
ruby -e 'require_relative "app"; $app.face_toggle; $app.led_toggle; puts "---"' 2>&1
```

Expected: フレームのecho（`<F:2>` / `<L:1,...>`）と、`face:joy` / `led:on:<色>` の行が両方出る。Swiftがparseするのはこの後者。

- [ ] **Step 6: Commit**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
git add examples/watchos/stackchan/app.rb examples/watchos/stackchan/test_frames.rb
git commit -F - <<'EOF'
feat(watch-stackchan): bundled Ruby for the watch controller + frame tests

app.rb is the iOS Stack-chan example reduced to three controls: a happy-face
toggle (smile <-> joy), a random-colour LED blink toggle, and a one-shot head
sweep that ends at neutral. Speak, torque and touch are out of scope, and
their codec helpers are removed rather than left unused.

Each dispatcher method prints a prefixed status line (face:/led:/head:) that
the Swift UI parses; the BLE links still echo every frame, so the prefix is
what makes the status line findable.

test_frames.rb runs under host CRuby against the recording BleLink stub and
asserts the exact wire bytes, including the load-bearing left/right reversal
and that the dropped helpers are really gone.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CoEkzNECosgLMsFZJfVrZ7
EOF
```

---

### Task 4: Swift層と `project.yml`、`rake watchos:stackchan:gen`

**Files:**
- Create: `examples/watchos/stackchan/Sources/WatchStackchan-Bridging-Header.h`
- Create: `examples/watchos/stackchan/Sources/App.swift`
- Create: `examples/watchos/stackchan/Sources/VMExecutor.swift`
- Create: `examples/watchos/stackchan/Sources/ContentView.swift`
- Create: `examples/watchos/stackchan/project.yml`
- Modify: `Rakefile`（`namespace :stackchan` に `gen` task を追加）

**Interfaces:**
- Consumes:
  - Task 3の `app.rb`（`connect` / `tick` / `face_toggle` / `led_toggle` / `head_sweep` と、その状態行のprefix）
  - `bridge/picoruby_bridge.h` の `void *vm_open(const char *boot_src)` / `char *vm_call(void *vm, const char *method, const char *arg)` / `void vm_close(void *vm)`
- Produces:
  - `VMExecutor.shared.start(bootSource:onResult:)` / `VMExecutor.shared.call(_:_:onResult:)`
  - Xcode project `examples/watchos/stackchan/WatchStackchan.xcodeproj`（scheme名 `WatchStackchan`）
  - rake task `watchos:stackchan:gen`

- [ ] **Step 1: Bridging Header**

Create `examples/watchos/stackchan/Sources/WatchStackchan-Bridging-Header.h`:

```c
#import "picoruby_bridge.h"
```

- [ ] **Step 2: `App.swift`**

Create `examples/watchos/stackchan/Sources/App.swift`:

```swift
import SwiftUI

@main
struct WatchStackchanApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

- [ ] **Step 3: `VMExecutor.swift`**

Create `examples/watchos/stackchan/Sources/VMExecutor.swift`:

```swift
import Foundation

// Owns the persistent PicoRuby VM. mruby is single-threaded, so vm_open /
// vm_call / vm_close MUST all run on ONE thread.
//
// On watchOS that thread cannot be a plain DispatchQueue: the system default
// stack is very small there and mruby's initialization overflows it. A
// dedicated Thread lets us set stackSize explicitly. The serial workQueue is
// pinned to that thread, and every VM touch is funnelled through it — the
// SwiftUI layer only ever posts closures here and never calls vm_* directly.
final class VMExecutor {
    static let shared = VMExecutor()

    private var vmThread: VMThread?
    private var timer: DispatchSourceTimer?

    private init() {}

    // Open the VM with the bundled app.rb as boot source. Starts the periodic
    // BLE pump tick once open.
    func start(bootSource: String, onResult: @escaping (String) -> Void) {
        guard vmThread == nil else { return }
        let t = VMThread(bootSource: bootSource, executor: self, onReady: onResult)
        t.stackSize = 4 * 1024 * 1024   // 4MB stack for mruby init
        vmThread = t
        t.start()
    }

    // Post a vm_call(method, arg) onto the VM thread; deliver captured output on
    // the main queue.
    func call(_ method: String, _ arg: String, onResult: @escaping (String) -> Void) {
        guard let thread = vmThread else {
            DispatchQueue.main.async { onResult("(VM not ready)") }
            return
        }
        thread.enqueue {
            guard let vm = thread.vm else {
                // Deliver on main like the happy path below: callers mutate
                // SwiftUI @State in onResult and must never run off-main.
                DispatchQueue.main.async { onResult("(VM not ready)") }
                return
            }
            let out = method.withCString { m in
                arg.withCString { a in vm_call(vm, m, a) }
            }
            let result = out.map { String(cString: $0) } ?? ""
            if let out = out { free(out) }
            // Mirror every call's captured VM output to NSLog so the watch
            // console/syslog carries it; the watch screen is too small for an
            // Output pane, so this is where bring-up output is read.
            NSLog("[WatchStackchan] %@(%@) ->\n%@", method, arg, result)
            DispatchQueue.main.async { onResult(result) }
        }
    }

    // Periodic BLE event pump. tick() drains the Swift FIFO; cheap when not
    // connected. Runs on the same serial queue so it never races a vm_call.
    fileprivate func startTick() {
        guard let thread = vmThread else { return }
        let t = DispatchSource.makeTimerSource(queue: thread.workQueue)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
        t.setEventHandler {
            guard let vm = thread.vm else { return }
            let out = "tick".withCString { m in
                "".withCString { a in vm_call(vm, m, a) }
            }
            let result = out.map { String(cString: $0) } ?? ""
            if let out = out { free(out) }
            // tick output is not UI-worthy, but silently dropping it hides a
            // recurring per-tick exception; keep it visible in the log.
            if !result.isEmpty { NSLog("[WatchStackchan] tick ->\n%@", result) }
        }
        t.resume()
        self.timer = t
    }
}

// Dedicated thread that owns the mruby VM. All VM calls must run on workQueue,
// which is pinned to this thread.
final class VMThread: Thread {
    var vm: UnsafeMutableRawPointer?
    let workQueue: DispatchQueue

    private let bootSource: String
    private weak var executor: VMExecutor?
    private let onReady: (String) -> Void

    init(bootSource: String, executor: VMExecutor, onReady: @escaping (String) -> Void) {
        self.bootSource = bootSource
        self.executor = executor
        self.onReady = onReady
        self.workQueue = DispatchQueue(label: "com.bash0c7.watchstackchan.vm")
        super.init()
    }

    func enqueue(_ work: @escaping () -> Void) {
        workQueue.async(execute: work)
    }

    override func main() {
        NSLog("[WatchStackchan] VMThread starting (stack: 4MB)")
        guard let handle = bootSource.withCString({ vm_open($0) }) else {
            NSLog("[WatchStackchan] vm_open returned NULL (app.rb failed to load)")
            DispatchQueue.main.async { self.onReady("(VM failed to start)") }
            return
        }
        vm = handle
        NSLog("[WatchStackchan] VM opened")
        DispatchQueue.main.async { self.onReady("VM ready") }
        executor?.startTick()
        // Keep the thread alive so workQueue's work actually runs on it.
        RunLoop.current.run()
    }
}
```

- [ ] **Step 4: `ContentView.swift`**

Create `examples/watchos/stackchan/Sources/ContentView.swift`:

```swift
import SwiftUI

// Stack-chan watch controller. Each row enqueues a vm_call onto the single VM
// thread (VMExecutor); the UI itself never touches the VM.
//
// app.rb echoes every BLE frame it writes, so the captured output of a call is
// not just the status line. Each handler scans the output's LINES for its own
// prefix (face: / led: / head:) rather than matching the whole string.
struct ContentView: View {
    @State private var status: String = "Starting VM…"
    @State private var connected: Bool = false
    @State private var connectFailed: Bool = false
    @State private var busy: Bool = false
    @State private var faceState: String = "smile"
    @State private var ledColor: String? = nil
    @State private var sweeping: Bool = false

    var body: some View {
        List {
            Button(action: connect) {
                HStack {
                    Circle().fill(statusColor).frame(width: 14, height: 14)
                    Text(connected ? "Connected" : "Connect")
                }
            }
            .disabled(busy)

            Button(action: faceToggle) {
                HStack {
                    Text(faceState == "joy" ? "😆" : "😊").font(.title2)
                    Text("Face")
                }
            }

            Button(action: ledToggle) {
                HStack {
                    Circle().fill(ledSwatch).frame(width: 14, height: 14)
                    Text(ledColor == nil ? "LED off" : "LED \(ledColor!)")
                }
            }

            Button(action: headSweep) {
                HStack {
                    Text("↻").font(.title2)
                    Text("ぐるっと")
                }
            }
            .disabled(sweeping)

            Text(status)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .onAppear { boot() }
    }

    // MARK: - derived appearance

    private var statusColor: Color {
        if connected { return .green }
        if connectFailed && !busy { return .red }
        return .gray
    }

    private var ledSwatch: Color {
        switch ledColor {
        case "red":     return .red
        case "green":   return .green
        case "blue":    return .blue
        case "yellow":  return .yellow
        case "cyan":    return .cyan
        case "magenta": return Color(red: 1, green: 0, blue: 1)
        default:        return .gray
        }
    }

    // MARK: - VM plumbing

    private func boot() {
        guard let url = Bundle.main.url(forResource: "app", withExtension: "rb"),
              let src = try? String(contentsOf: url, encoding: .utf8) else {
            status = "could not read app.rb"
            return
        }
        VMExecutor.shared.start(bootSource: src) { result in
            self.status = result
        }
    }

    // The last line of `output` that starts with `prefix`, minus the prefix.
    private func statusLine(_ output: String, prefix: String) -> String? {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .last(where: { $0.hasPrefix(prefix) })
            .map { String($0.dropFirst(prefix.count)) }
    }

    // MARK: - actions

    // Connect blocks the VM thread for the scan's duration (SCAN_TIMEOUT_MS in
    // app.rb, 10 s): reflect that immediately and keep the button single-flight
    // so a second tap cannot queue another scan behind the first.
    private func connect() {
        busy = true
        connectFailed = false
        status = "Scanning…"
        VMExecutor.shared.call("connect", "") { result in
            self.connected = result.contains("Connected; RX value_handle bound")
            self.connectFailed = !self.connected
            self.status = self.connected ? "connected" : "not found"
            self.busy = false
        }
    }

    private func faceToggle() {
        VMExecutor.shared.call("face_toggle", "") { result in
            if let face = self.statusLine(result, prefix: "face:") {
                self.faceState = face
                self.status = "face \(face)"
            } else {
                self.status = "face: no reply"
            }
        }
    }

    private func ledToggle() {
        VMExecutor.shared.call("led_toggle", "") { result in
            guard let led = self.statusLine(result, prefix: "led:") else {
                self.status = "led: no reply"
                return
            }
            if led == "off" {
                self.ledColor = nil
                self.status = "led off"
            } else if led.hasPrefix("on:") {
                let color = String(led.dropFirst("on:".count))
                self.ledColor = color
                self.status = "led \(color)"
            }
        }
    }

    // head_sweep blocks the VM thread for ~1.8 s: single-flight like connect.
    private func headSweep() {
        sweeping = true
        status = "sweeping…"
        VMExecutor.shared.call("head_sweep", "") { result in
            self.status = self.statusLine(result, prefix: "head:") != nil
                ? "swept" : "sweep: no reply"
            self.sweeping = false
        }
    }
}
```

- [ ] **Step 5: `project.yml`**

Create `examples/watchos/stackchan/project.yml`:

```yaml
name: WatchStackchan
options:
  bundleIdPrefix: com.bash0c7.picoruby
  deploymentTarget:
    watchOS: "26.0"
packages:
  # The Darwin (CoreBluetooth) BLE backend Swift package, built here in its
  # central-only watchOS configuration. Its pble_* C symbols resolve the
  # undefined references in the staged libmruby.a at app link time.
  PicoBLEDarwin:
    path: ../../../vendor/picoruby/mrbgems/picoruby-ble/ports/darwin/ext
targets:
  WatchStackchan:
    type: application
    platform: watchOS
    sources:
      - path: Sources
      - path: app.rb
        buildPhase: resources
      - path: ../../../bridge
        includes:
          - "picoruby_bridge.c"
          - "picoruby_bridge.h"
          - "task_hal_ios.c"
    dependencies:
      # Dynamic Swift-package product: link AND embed so dyld can resolve the
      # pble_* symbols (the framework lands in the app's Frameworks/ dir).
      - package: PicoBLEDarwin
        embed: true
    settings:
      base:
        SWIFT_OBJC_BRIDGING_HEADER: Sources/WatchStackchan-Bridging-Header.h
        GCC_PREPROCESSOR_DEFINITIONS:
          - "$(inherited)"
          - "PICORB_ALLOC_ESTALLOC"
          - "PICORB_ALLOC_ALIGN=8"
          - "MRB_NO_BOXING"
          - "MRB_INT64"
          - "MRB_UTF8_STRING"
          - "PICORB_PLATFORM_POSIX"
          - "PICORB_PLATFORM_DARWIN"
          - "MRB_TICK_UNIT=4"
          - "MRB_TIMESLICE_TICK_COUNT=3"
          - "MRB_USE_TASK_SCHEDULER=1"
          - "MRB_USE_VM_SWITCH_DISPATCH=1"
          - "MRB_BASELINE_PROFILE=1"
          # The bridge defaults to 8MB. led-toggle runs a bare VM in 2MB; this
          # VM additionally carries picoruby-ble and mbedtls, so 4MB. See the
          # heap tuning note in Task 6 if the app is jetsam-killed or the VM
          # fails to open.
          - "HEAP_SIZE=4194304"
        HEADER_SEARCH_PATHS:
          - "$(SRCROOT)/../../../vendor/picoruby/include"
          - "$(SRCROOT)/../../../vendor/picoruby/mrbgems/mruby-compiler/include"
          - "$(SRCROOT)/../../../vendor/picoruby/mrbgems/mruby-compiler/lib/prism/include"
          - "$(SRCROOT)/../../../vendor/picoruby/mrbgems/picoruby-mruby/lib/mruby/include"
          - "$(SRCROOT)/../../../vendor/picoruby/mrbgems/picoruby-mruby/include"
          - "$(SRCROOT)/../../../build/watchos-stackchan-sim/include"
          - "$(SRCROOT)/../../../build/watchos-stackchan-device/include"
          - "$(SRCROOT)/../../../vendor/picoruby/mrbgems/picoruby-mruby/lib/mruby/mrbgems/mruby-task/include"
          - "$(SRCROOT)/../../../bridge"
        LIBRARY_SEARCH_PATHS:
          - "$(SRCROOT)/Vendor/lib"
        # -framework Security resolves SecRandomCopyBytes, the entropy source of
        # the mbedtls / rng Darwin ports picoruby-ble pulls in (ble.rb requires
        # mbedtls at boot); the staged archive leaves it undefined.
        OTHER_LDFLAGS:
          - "-lmruby"
          - "-framework"
          - "Security"
        GENERATE_INFOPLIST_FILE: "YES"
        INFOPLIST_KEY_WKApplication: "YES"
        INFOPLIST_KEY_WKWatchOnly: "YES"
        INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription: "Connect to your Stack-chan robot over Bluetooth."
        TARGETED_DEVICE_FAMILY: "4"
        PRODUCT_BUNDLE_IDENTIFIER: com.bash0c7.picoruby.WatchStackchan
        CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: SM5792D355  # Apple Team ID (Xcode > Settings > Accounts) for device builds
```

- [ ] **Step 6: Rakefile に `gen` task を追加**

Task 2で追加した `namespace :stackchan do` ブロックの `task lib:` の **後ろ** に挿入する。

```ruby
    desc "Generate the Watch Stack-chan Xcode project from project.yml"
    task :gen do
      sh "cd #{ws_dir.shellescape} && xcodegen generate"
    end
```

- [ ] **Step 7: project を生成**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
rake watchos:stackchan:gen
```

Expected: 成功し、`Created project at .../examples/watchos/stackchan/WatchStackchan.xcodeproj` が出る。

- [ ] **Step 8: scheme が見えることを確認**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
xcodebuild -project examples/watchos/stackchan/WatchStackchan.xcodeproj -list
```

Expected: `Schemes:` に `WatchStackchan` が出る。

- [ ] **Step 9: 生成物を .gitignore から確認して Commit**

`.xcodeproj` は他のexampleがどう扱っているかに合わせる。

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
git check-ignore -v examples/watchos/stackchan/WatchStackchan.xcodeproj/project.pbxproj || echo "NOT IGNORED"
git ls-files examples/watchos/led-toggle/WatchLEDToggle.xcodeproj | head
```

led-toggleの `.xcodeproj` がtrackされていれば、こちらもtrackする。ignoreされていればそれに従う。

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
git add examples/watchos/stackchan/Sources examples/watchos/stackchan/project.yml Rakefile
# led-toggle の .xcodeproj が tracked なら次も足す
git add examples/watchos/stackchan/WatchStackchan.xcodeproj 2>/dev/null || true
git commit -F - <<'EOF'
feat(watch-stackchan): SwiftUI host, VM-owning thread, and the Xcode project

VMExecutor follows led-toggle's watchOS shape — a dedicated Thread with a 4MB
stack, since the default DispatchQueue stack overflows during mruby init —
and carries the iOS example's call(method, arg) API plus the 1 s BLE pump.

ContentView is a four-row List: connect, face toggle, LED toggle, head sweep,
with a caption status line. Because app.rb echoes every frame it writes, each
handler scans the captured output's lines for its own prefix rather than
matching the whole string. Connect and head sweep are single-flight; they
block the VM thread for 10 s and ~1.8 s respectively.

project.yml links and embeds the PicoBLEDarwin package and sets HEAP_SIZE to
4MB, between led-toggle's bare-VM 2MB and the bridge's 8MB default, because
this VM also carries picoruby-ble and mbedtls.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CoEkzNECosgLMsFZJfVrZ7
EOF
```

---

### Task 5: watchOS Simulator でリンクが通る

**Files:**
- Modify: `Rakefile`（`namespace :stackchan` に `build` / `run` / `all` task を追加）

**Interfaces:**
- Consumes: Task 2の `watchos:stackchan:lib`、Task 4の `watchos:stackchan:gen` と `WatchStackchan.xcodeproj`
- Produces: rake task `watchos:stackchan:build` / `:run` / `:all`、および `build/watchos-stackchan-app/Build/Products/*-watchsimulator/WatchStackchan.app`

- [ ] **Step 1: Rakefile に build / run / all を追加**

`namespace :stackchan do` ブロックの `task :gen` の **後ろ** に挿入する。

```ruby
    desc "Build the Watch Stack-chan app for the watchOS Simulator"
    task :build do
      sim_build(ws_proj, "WatchStackchan", ws_derived,
                platform: "watchOS Simulator", exclude_x86_64: false)
    end

    desc "Boot a watchOS simulator, install, and launch the Watch Stack-chan app"
    task :run do
      app = built_app(ws_derived, "*-watchsimulator", "WatchStackchan", "watchos:stackchan:build")
      sim_install_launch("Apple Watch", app, ws_bundle)
    end

    desc "Full Watch Stack-chan pipeline: lib -> gen -> build -> run"
    task all: [:lib, :gen, :build, :run]
```

- [ ] **Step 2: define parity を突合する**

`project.yml` の `GCC_PREPROCESSOR_DEFINITIONS` と、libmruby.a が実際にコンパイルされたときの `-D` が一致していなければならない。不一致は `sizeof(mrb_state)` に効き、bridge と lib の間のメモリ破壊になる。`MRB_BASELINE_PROFILE=1` のようにconfigに書かれずgemがbuild-wideに足すdefineがあるので、目視ではなく実際のcompile commandから抽出して突き合わせる。

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin/vendor/picoruby
MRUBY_BUILD_DIR=/Users/bash/dev/src/github.com/bash0C7/R2P2-darwin/build \
MRUBY_CONFIG=/Users/bash/dev/src/github.com/bash0C7/R2P2-darwin/build_config/r2p2-picoruby-watchos-stackchan-sim.rb \
rake -v 2>&1 \
  | grep -o -- '-D[A-Za-z_][A-Za-z0-9_]*\(=[^ ]*\)\?' \
  | sed 's/^-D//' | sort -u > /tmp/lib_defines.txt
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
grep -o '"[A-Z][A-Z0-9_]*\(=[^"]*\)\?"' examples/watchos/stackchan/project.yml \
  | tr -d '"' | sort -u > /tmp/app_defines.txt
echo "=== lib にあって app.yml に無い ==="
comm -23 /tmp/lib_defines.txt /tmp/app_defines.txt
```

`rake -v` は既にビルド済みなら何もcompileせず `-D` を出さないことがある。その場合は先に `rm -rf build/watchos-stackchan-sim` してから流す。

Expected: `PICORB_ALLOC_ESTALLOC` / `PICORB_ALLOC_ALIGN=8` / `MRB_NO_BOXING` / `MRB_INT64` / `MRB_UTF8_STRING` / `PICORB_PLATFORM_POSIX` / `PICORB_PLATFORM_DARWIN` / `MRB_TICK_UNIT=4` / `MRB_TIMESLICE_TICK_COUNT=3` / `MRB_USE_TASK_SCHEDULER` / `MRB_BASELINE_PROFILE=1` のうち、`sizeof(mrb_state)` に効くものが差分に出ないこと。

差分に出るものがあれば `project.yml` の `GCC_PREPROCESSOR_DEFINITIONS` に足す。`HEAP_SIZE` はbridge専用なのでlib側に出なくて正しい。`NDEBUG` / `HAVE_MRUBY_IO_GEM` / `PICORB_VM_MRUBY` は既存exampleの `project.yml` にも書かれていないので、そこに揃える（違いが出た場合はled-toggleとiOS stackchanの `project.yml` を見て、同じ扱いにする）。

`comm` の差分に対して `project.yml` を直した場合は、`rm -rf build/watchos-stackchan-app` してからStep 3へ進む。

- [ ] **Step 3: リンクを通す**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
rake watchos:stackchan:build
```

Expected: `** BUILD SUCCEEDED **`。

長いビルドログが出るので、subagentに投げる場合はhaikuに「コマンドをverbatimで実行し、raw outputをそのまま返す」よう指示すること。

**失敗したときの読み方:**

| 症状 | 原因と対処 |
|---|---|
| `Undefined symbol: _pble_peripheral_*` | Task 1のStep 4の `#else` 側stubが漏れている。7つのexport全部あるか確認 |
| `Undefined symbol: _SecRandomCopyBytes` | `OTHER_LDFLAGS` の `-framework Security` が落ちている |
| `'init(delegate:queue:)' is unavailable in watchOS` | Task 1の `#if !os(watchOS)` が `PicoBLEPeripheral.swift` 全体を囲えていない。`rake refresh` で vendor に反映されているかも確認 |
| `library 'mruby' not found` | `rake watchos:stackchan:lib` が未実行、または `LIBRARY_SEARCH_PATHS` の `Vendor/lib` に staged されていない |
| `building for watchOS Simulator, but linking ... built for macOS` | libmruby.a のSDKが違う。`rm -rf build/watchos-stackchan-sim` して `rake watchos:stackchan:lib` からやり直す |
| `The platform 'watchOS' is not supported by package 'PicoBLEDarwin'` | Task 1のStep 2（`Package.swift` の `.watchOS(.v6)`）が vendor に反映されていない。`rake refresh` |

- [ ] **Step 4: .app ができていることを確認**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
APP=$(ls -d build/watchos-stackchan-app/Build/Products/*-watchsimulator/WatchStackchan.app)
echo "$APP"
ls "$APP"
ls "$APP/Frameworks" 2>/dev/null
ls "$APP/app.rb"
```

Expected:
- `.app` が存在する
- `Frameworks/` に `PicoBLEDarwin.framework` がある（`embed: true` が効いている）
- `app.rb` がバンドルされている（`buildPhase: resources` が効いている）

- [ ] **Step 5: Commit**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
git add Rakefile
git commit -F - <<'EOF'
build: watchos:stackchan build/run/all rake tasks

Simulator build mirrors watchos:led — ARCHS=arm64 without EXCLUDED_ARCHS,
since libmruby.a is arm64 only and the watch simulator destination is too.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CoEkzNECosgLMsFZJfVrZ7
EOF
```

---

### Task 6: watchOS Simulator で起動する（この計画の完了ライン）

**Files:** なし（既存taskの実行と、必要ならHEAP_SIZEの調整）

**Interfaces:**
- Consumes: Task 5の `watchos:stackchan:build` が出した `.app`
- Produces: SimulatorでVMがbootし、UIが操作できるという実証

- [ ] **Step 1: Simulator にインストールして起動**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
rake watchos:stackchan:run
```

Expected: 成功。`xcrun simctl launch` がPIDを返し、Simulatorに時計盤ではなくアプリが出る。

- [ ] **Step 2: VM が boot したことをログで確認**

launchから数秒待ってから、SimulatorのログでVMのbootを確認する。

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
UDID=$(xcrun simctl list devices available | grep -m1 "Apple Watch" | grep -o '[0-9A-F-]\{36\}')
echo "UDID=$UDID"
xcrun simctl spawn "$UDID" log show --last 2m --predicate 'eventMessage CONTAINS "WatchStackchan"' --style compact 2>/dev/null | head -40
```

Expected: 次の2行が出ている。

```
[WatchStackchan] VMThread starting (stack: 4MB)
[WatchStackchan] VM opened
```

`vm_open returned NULL (app.rb failed to load)` が出ている場合は `app.rb` が縮小VMでコンパイルできていない。ログにprismの診断が出ているはずなので、それを読んで `app.rb` を直す（host CRubyは通るがPicoRubyは通らない構文の可能性）。

- [ ] **Step 3: UI を操作して各コントロールが VM に届くことを確認**

Simulatorのアプリで Face → LED → ぐるっと → Connect の順にタップする。GUI操作なのでこのステップだけは人手が要る。

タップ後に同じlogコマンドを流して、各 `vm_call` の記録を確認する。

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
UDID=$(xcrun simctl list devices available | grep -m1 "Apple Watch" | grep -o '[0-9A-F-]\{36\}')
xcrun simctl spawn "$UDID" log show --last 3m --predicate 'eventMessage CONTAINS "WatchStackchan"' --style compact 2>/dev/null | tail -40
```

Expected: 次のような行が出る。

```
[WatchStackchan] face_toggle() ->
<F:2>
face:joy
[WatchStackchan] led_toggle() ->
<L:1,R:0,G:255,B:255,S:B,M:b>
led:on:cyan
[WatchStackchan] head_sweep() ->
<YL:60,T:500>
<YR:60,T:500>
<PU:40,T:500>
<YL:0,PU:0,T:400>
head:done
[WatchStackchan] connect() ->
Scanning for Stack-chan (NUS)
No Stack-chan found. Check: robot powered on? Bluetooth on?
```

画面側では、Face行の絵文字が 😊 → 😆 に変わり、LED行の丸が色付きになり、ぐるっと行が約1.8秒disabledになり、Connect行の丸が赤（not found）になる。

**Simulatorでは実際のBLE無線が無いので、Connectが `No Stack-chan found` で終わるのが正しい挙動。** これを失敗とみなさない。

- [ ] **Step 4: VM が生きたままであることを確認（クラッシュしていない）**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
UDID=$(xcrun simctl list devices available | grep -m1 "Apple Watch" | grep -o '[0-9A-F-]\{36\}')
xcrun simctl spawn "$UDID" log show --last 3m --predicate 'eventMessage CONTAINS "WatchStackchan"' --style compact 2>/dev/null \
  | grep -E "EXC_BAD_ACCESS|est_free|remove_free_block|trace \(most recent call last\)" || echo "NO CRASH, NO RUBY BACKTRACE"
```

Expected: `NO CRASH, NO RUBY BACKTRACE`。

- [ ] **Step 5: HEAP_SIZE の判断**

Step 2〜4が全て通ったなら `HEAP_SIZE=4194304` のままでよい。次の症状が出た場合のみ調整する。

| 症状 | 対処 |
|---|---|
| `vm_open returned NULL` かつログにprism診断が無い | ヒープ不足。`project.yml` の `HEAP_SIZE` を `8388608`（8MB）に上げ、`rm -rf build/watchos-stackchan-app` してTask 5 Step 2からやり直す |
| 操作中に `est_free` / `remove_free_block` を含むクラッシュ | 同上（ヒープ枯渇によるアロケータ破壊） |
| アプリが数秒で無言で消える（jetsam） | ヒープ過大。`2097152`（2MB、led-toggleと同じ）に下げて同様にやり直す |

調整した場合は `project.yml` のHEAP_SIZEコメントを実測値の根拠に書き換えて、その旨をcommit messageに残す。

- [ ] **Step 6: 実行結果の commit（コード変更があった場合のみ）**

Step 5でHEAP_SIZEを変えた場合だけcommitする。変更が無ければこのステップはskip。

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
git add examples/watchos/stackchan/project.yml
git commit -F - <<'EOF'
fix(watch-stackchan): set HEAP_SIZE from the observed Simulator behaviour

<実際に観測した症状と、選んだ値の根拠を1〜2行で書く>

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CoEkzNECosgLMsFZJfVrZ7
EOF
```

---

### Task 7: watchOS device（arm64_32）のリンクを通す

実機は未接続だが、`device:lib` も `device:check` も実機を必要としない。device SDK固有の破綻（device SDKがunavailableとマークするAPI、device archiveに無いportシンボル）はここで出る。

**Files:**
- Create: `build_config/r2p2-picoruby-watchos-stackchan-device.rb`
- Modify: `build_config/recompile_arm64_32.rb`（build名とconfig名を引数化）
- Modify: `Rakefile`（`namespace :stackchan` に `namespace :device` を追加、および `watchos:led:device:lib` の呼び出しを新しい引数付きに更新）

**Interfaces:**
- Consumes: Task 1のwatchOS device typecheck、Task 4の `WatchStackchan.xcodeproj`
- Produces:
  - MRuby build名 `watchos-stackchan-device`
  - rake task `watchos:stackchan:device:lib` / `:build` / `:check` / `:run` / `:all`
  - `recompile_arm64_32.rb` のCLI: `ruby build_config/recompile_arm64_32.rb <build_name> <config_basename>`（引数省略時は従来どおり `watchos-device` / `r2p2-picoruby-watchos-device.rb`）

- [ ] **Step 1: device 用 build_config を書く**

Create `build_config/r2p2-picoruby-watchos-stackchan-device.rb`:

```ruby
# watchOS device (arm64_32) cross-build for the Stack-chan watch example:
# the bare picoruby VM/compiler PLUS picoruby-ble built with its Apple/Darwin
# (CoreBluetooth) port, in the central role only. EXAMPLE-SCOPED — BLE lives
# only in this config so the led-toggle example's libmruby.a keeps linking
# without it.
#
# Device counterpart of r2p2-picoruby-watchos-stackchan-sim.rb; see that file
# for the full rationale on the darwin? fallback, the conf.ports :darwin port
# selection, hal-io-darwin, and why the picoruby-mbedtls dependency stays.
# Differs only in the watchos SDK and the device version-min flag.
#
# The -arch arm64_32 flag here does not by itself yield an arm64_32-only
# archive: some objects still come out arm64, so watchos:stackchan:device:lib
# runs build_config/recompile_arm64_32.rb afterwards to rebuild them.

sdk_path    = `xcrun --sdk watchos --show-sdk-path`.strip
clang       = `xcrun --sdk watchos --find clang`.strip
ar          = `xcrun --sdk watchos --find ar`.strip
watchos_min = ENV["WATCHOS_MIN"] || "11.0"

module MRuby
  class Build
    def darwin?
      false
    end unless method_defined?(:darwin?)
  end
end

MRuby::CrossBuild.new("watchos-stackchan-device") do |conf|
  conf.toolchain :clang

  # The gcc/clang toolchain adds -lm by default, but libm is part of libSystem
  # on Apple platforms and the SDK marks it unavailable as a separate library.
  # Remove it to avoid link failure.
  conf.linker.libraries.delete("m")

  conf.cc.command       = clang
  conf.linker.command   = clang
  conf.archiver.command = ar
  conf.cc.host_command  = "clang"   # builds mrbc / compiler for the host

  conf.cc.flags << "-arch" << "arm64_32"
  conf.cc.flags << "-isysroot" << sdk_path
  conf.cc.flags << "-mwatchos-version-min=#{watchos_min}"

  conf.cc.defines << "MRB_TICK_UNIT=4"
  conf.cc.defines << "MRB_TIMESLICE_TICK_COUNT=3"
  conf.cc.defines << "PICORB_ALLOC_ALIGN=8"
  conf.cc.defines << "PICORB_ALLOC_ESTALLOC"
  conf.cc.defines << "PICORB_PLATFORM_POSIX"   # Darwin IS POSIX (XNU + BSD libc)
  conf.cc.defines << "PICORB_PLATFORM_DARWIN"  # ...and darwin (additive)
  conf.cc.defines << "MRB_INT64"
  conf.cc.defines << "MRB_NO_BOXING"
  conf.cc.defines << "MRB_UTF8_STRING"

  conf.picoruby

  conf.gem core: "mruby-compiler"

  mruby_mrbgems = "#{MRUBY_ROOT}/mrbgems/picoruby-mruby/lib/mruby/mrbgems"
  conf.gem gemdir: "#{mruby_mrbgems}/mruby-string-ext"
  conf.gem gemdir: "#{mruby_mrbgems}/mruby-pack"
  conf.gem gemdir: "#{mruby_mrbgems}/mruby-sprintf"
  conf.gem gemdir: "#{mruby_mrbgems}/mruby-random"

  # --- Stack-chan: picoruby-ble + CoreBluetooth Darwin port -----------------
  conf.ports :darwin, :posix
  conf.gem core: "picoruby-machine"
  conf.gem core: "hal-io-darwin"

  ble_gemdir = ENV["PICORUBY_BLE_GEMDIR"] ||
    File.expand_path("../vendor/picoruby/mrbgems/picoruby-ble", __dir__)

  conf.cc.include_paths << "#{ble_gemdir}/ports/darwin/ext"

  conf.gem ble_gemdir
end
```

- [ ] **Step 2: `recompile_arm64_32.rb` を引数化**

`build_config/recompile_arm64_32.rb` の先頭ブロックを差し替える。

変更前:
```ruby
#!/usr/bin/env ruby
# Recompile arm64 objects in build/watchos-device as arm64_32
# and create a proper arm64_32 libmruby.a for watchOS device.
#
# Run from worktree root: ruby build_config/recompile_arm64_32.rb

require 'shellwords'

ROOT      = File.expand_path("..", __dir__)
BUILD_DIR = File.join(ROOT, "build", "watchos-device")
SDK       = `xcrun --sdk watchos --show-sdk-path`.strip
CLANG     = `xcrun --sdk watchos --find clang`.strip
AR        = `xcrun --sdk watchos --find ar`.strip
```

変更後:
```ruby
#!/usr/bin/env ruby
# Recompile arm64 objects in a watchOS device build dir as arm64_32
# and create a proper arm64_32 libmruby.a for watchOS device.
#
# Run from worktree root:
#   ruby build_config/recompile_arm64_32.rb [build_name] [config_basename]
#
# Defaults keep the led-toggle invocation working unchanged:
#   build_name       "watchos-device"
#   config_basename  "r2p2-picoruby-watchos-device.rb"
#
# The Stack-chan watch example passes its own pair:
#   ruby build_config/recompile_arm64_32.rb \
#     watchos-stackchan-device r2p2-picoruby-watchos-stackchan-device.rb

require 'shellwords'

BUILD_NAME      = ARGV[0] || "watchos-device"
CONFIG_BASENAME = ARGV[1] || "r2p2-picoruby-watchos-device.rb"

ROOT      = File.expand_path("..", __dir__)
BUILD_DIR = File.join(ROOT, "build", BUILD_NAME)
SDK       = `xcrun --sdk watchos --show-sdk-path`.strip
CLANG     = `xcrun --sdk watchos --find clang`.strip
AR        = `xcrun --sdk watchos --find ar`.strip

raise "build dir not found: #{BUILD_DIR} (run the device lib task first)" unless Dir.exist?(BUILD_DIR)
puts "Recompiling #{BUILD_NAME} against #{CONFIG_BASENAME}"
```

続く `CONFIG_RB` の行を差し替える。

変更前:
```ruby
CONFIG_RB = File.join(__dir__, "r2p2-picoruby-watchos-device.rb")
```

変更後:
```ruby
CONFIG_RB = File.join(__dir__, CONFIG_BASENAME)
```

**残りは一切変えない。** cc.definesをconfigファイルから読み取る仕組みと `watchos_min` のparseは、再コンパイルするobjectがdefineでdriftしないための単一ソース。崩すとサイレントなオンデバイス破壊になる。

`INCLUDES` の配列にはビルド固有のパス `build/watchos-device/include` が入っているので、そこも引数に追随させる。

変更前:
```ruby
INCLUDES = [
  "build/watchos-device/include",
```

変更後:
```ruby
INCLUDES = [
  File.join("build", BUILD_NAME, "include"),
```

- [ ] **Step 3: led-toggle の device:lib が引数なしでも従来どおり動くことを確認**

引数のデフォルトが効いているかを、実際に走らせずに確認する。

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
ruby -c build_config/recompile_arm64_32.rb
ruby build_config/recompile_arm64_32.rb 2>&1 | head -3
```

Expected: `Syntax OK` が出る。2つ目のコマンドは `build/watchos-device` が無ければ
`build dir not found: .../build/watchos-device (run the device lib task first)` で止まる（これが期待動作）。存在すれば `Recompiling watchos-device against r2p2-picoruby-watchos-device.rb` から始まる。

- [ ] **Step 4: Rakefile の led device:lib を明示引数に更新**

`namespace :led` の `namespace :device` 内、`task lib: :setup do` の中の行を変更する。

変更前:
```ruby
        sh "ruby #{File.join(ROOT, "build_config", "recompile_arm64_32.rb").shellescape}"
```

変更後:
```ruby
        sh "ruby #{File.join(ROOT, "build_config", "recompile_arm64_32.rb").shellescape} " \
           "watchos-device r2p2-picoruby-watchos-device.rb"
```

デフォルト引数があるので機能は変わらないが、2つの呼び出し元が対称に読めるようにする。

- [ ] **Step 5: Rakefile に stackchan の device namespace を追加**

`namespace :stackchan do` ブロックの `task all:` の **後ろ**（`namespace :stackchan` の `end` の直前）に挿入する。

```ruby
    namespace :device do
      desc "Cross-build libmruby.a for watchOS device (arm64_32, BLE) and stage under examples/watchos/stackchan/Vendor (env: WATCHOS_MIN)"
      task lib: :setup do
        stage_libmruby("r2p2-picoruby-watchos-stackchan-device.rb", "watchos-stackchan-device", ws_vendor)
        # stage_libmruby copies the fat/arm64 archive mruby just built; the
        # physical watch needs arm64_32. Recompile in place and re-stage so
        # Vendor/lib never ends up with an arch the device can't run.
        sh "ruby #{File.join(ROOT, "build_config", "recompile_arm64_32.rb").shellescape} " \
           "watchos-stackchan-device r2p2-picoruby-watchos-stackchan-device.rb"
        lib = File.join(BUILD_DIR, "watchos-stackchan-device", "lib", "libmruby.a")
        cp lib, File.join(ws_vendor, "lib", "libmruby.a")
        puts "Re-staged arm64_32 libmruby.a under #{ws_vendor}"
      end

      desc "Build the Watch Stack-chan app, signed, for the connected Apple Watch"
      task :build do
        device_build(ws_proj, "WatchStackchan", ws_device_derived,
                     archs: "arm64_32", platform: "watchOS")
      end

      desc "Link the Watch Stack-chan app for a generic watchOS device without signing (no watch needed)"
      task :check do
        device_check_build(ws_proj, "WatchStackchan", ws_device_derived,
                           archs: "arm64_32", platform: "watchOS")
      end

      desc "Install and launch the Watch Stack-chan app on the connected Apple Watch"
      task :run do
        app = built_app(ws_device_derived, "*-watchos", "WatchStackchan", "watchos:stackchan:device:build")
        device_install_launch(/Watch/, "Apple Watch", app, ws_bundle)
      end

      desc "Full Watch Stack-chan device pipeline: lib -> gen -> build -> run (needs a connected, signed Apple Watch)"
      task all: [:lib, "watchos:stackchan:gen", :build, :run]
    end
```

- [ ] **Step 6: device 用 libmruby.a をビルド**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
rm -rf build/watchos-stackchan-device
rake watchos:stackchan:device:lib
```

Expected: 成功し、末尾に `Re-staged arm64_32 libmruby.a under .../examples/watchos/stackchan/Vendor` が出る。

途中の `N compiled OK, M failed` の行を必ず読むこと。**`M` が0でない場合、mbedtlsなどのソースがarm64_32で通っていない。** その `FAIL:` 行を全部拾ってuserへ報告する。specの「未解決のリスク1」がこれ。古いSHAへのpinで逃げてはならない。

- [ ] **Step 7: arm64_32 になっていることを確認**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
lipo -info examples/watchos/stackchan/Vendor/lib/libmruby.a
```

Expected: `arm64_32` を報告する（`arm64` ではなく）。

- [ ] **Step 8: 署名なしの device リンクを通す**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
rake watchos:stackchan:device:check
```

Expected: `** BUILD SUCCEEDED **`。

これはdevice SDK固有の破綻を捕まえるためのステップ。実機も署名も要らない。

- [ ] **Step 9: led-toggle の device リンクが壊れていないことを確認**

`recompile_arm64_32.rb` を触ったので、既存の呼び出し元を実際に走らせる。

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
rm -rf build/watchos-device
rake watchos:led:device:lib
lipo -info examples/watchos/led-toggle/Vendor/lib/libmruby.a
rake watchos:led:device:check
```

Expected: `arm64_32` を報告し、`** BUILD SUCCEEDED **`。

- [ ] **Step 10: Commit**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
git add build_config/r2p2-picoruby-watchos-stackchan-device.rb \
        build_config/recompile_arm64_32.rb Rakefile
git commit -F - <<'EOF'
build: watchOS device (arm64_32) config and tasks for the Stack-chan watch app

recompile_arm64_32.rb now takes the build name and config basename as
arguments, defaulting to the led-toggle pair so the existing call site keeps
working. The mechanism that reads cc.defines and watchos_min out of the
build_config is untouched: it is what keeps the recompiled objects from
drifting on a define, which would be a silent on-device corruption.

device:check links the app for a generic watchOS device without signing, so
device-SDK-only breakage surfaces without a watch on the desk.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CoEkzNECosgLMsFZJfVrZ7
EOF
```

---

### Task 8: リグレッション確認と README

**Files:**
- Create: `examples/watchos/stackchan/README.md`
- Create: `examples/watchos/stackchan/README_jp.md`
- Modify: `README.md`（repo直下）
- Modify: `README_jp.md`（repo直下）

**Interfaces:**
- Consumes: Task 1〜7の全て
- Produces: なし（ドキュメントと検証）

- [ ] **Step 1: host の smoke test**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
rake smoke
```

Expected: 成功。`vendor/picoruby` がTask 1で更新されているので、ここが壊れていないことを確認する意味がある。

- [ ] **Step 2: iOS Stack-chan のリグレッション確認**

Task 1のfork変更が `#if !os(watchOS)` の外側に影響していないことを、実際のビルドで確かめる。

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
ruby examples/ios/stackchan/test_frames.rb
rake ios:stackchan:device:check
```

Expected: `all passed` と `** BUILD SUCCEEDED **`。

`ios:stackchan:device:check` が `library 'mruby' not found` で落ちる場合は、先に `rake ios:stackchan:device:lib` が要る。その場合はそれを実行してからやり直す。

- [ ] **Step 3: virtual-peripheral のリグレッション確認**

peripheralロールを実際に使う唯一のexampleなので、ここが通れば `#if !os(watchOS)` が iOS を壊していないと言える。

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
rake -T ios:vperiph
```

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
rake ios:vperiph:device:check
```

Expected: `** BUILD SUCCEEDED **`。

`library 'mruby' not found` で落ちる場合は `rake ios:vperiph:device:lib` を先に走らせてからやり直す。

- [ ] **Step 4: example の README を書く**

Create `examples/watchos/stackchan/README.md`:

```markdown
# Watch Stack-chan

A watchOS-only Stack-chan controller. The PicoRuby VM runs on the Apple Watch
and drives picoruby-ble's central role directly over CoreBluetooth — there is no
iPhone companion app. It is a subset of [`../../ios/stackchan`](../../ios/stackchan)
with three controls:

- **Face** — toggles between two happy faces, `smile` and `joy`
- **LED** — toggles a blink in a randomly chosen colour, and off again
- **ぐるっと (sweep)** — one tap sends left → right → up → neutral

Speak (subtitle + mu-law audio), torque, and touch events are out of scope here;
the iOS example carries those.

## Why the fork carries a watchOS change

watchOS declares the `CBPeripheralManager`, `CBMutableService` and
`CBMutableCharacteristic` initializers `API_UNAVAILABLE`, so picoruby-ble's
Darwin port cannot compile its peripheral backend for the watch. In
`bash0C7/picoruby` (`port-darwin`), `PicoBLEPeripheral.swift` is wrapped in
`#if !os(watchOS)` and the `pble_peripheral_*` exports become no-op stubs —
`ble_peripheral.c` still enters the watchOS archive and references them, so the
symbols must exist even though the role does not. The central role is fully
available on watchOS.

## Verify the wire format without a watch

The frame encoders are plain Ruby, so host CRuby produces byte-identical frames
to the reduced PicoRuby VM:

```
ruby examples/watchos/stackchan/test_frames.rb   # all PASS
```

## Simulator

```
rake watchos:stackchan:all     # lib -> gen -> build -> run
```

The Simulator has no Bluetooth radio, so **Connect ending in "not found" is the
correct behaviour there**. What the Simulator does prove is that the VM boots,
`app.rb` compiles in-app, and every control reaches the VM. Read the captured VM
output with:

```
UDID=$(xcrun simctl list devices available | grep -m1 "Apple Watch" | grep -o '[0-9A-F-]\{36\}')
xcrun simctl spawn "$UDID" log show --last 5m \
  --predicate 'eventMessage CONTAINS "WatchStackchan"' --style compact
```

## Physical Apple Watch

```
rake watchos:stackchan:device:lib     # arm64_32 libmruby.a (BLE)
rake watchos:stackchan:device:check   # link for a generic watch, unsigned — no watch needed
rake watchos:stackchan:device:all     # lib -> gen -> build -> run (needs a paired, connected watch)
```

## How the UI reads the VM

`app.rb` echoes every BLE frame it writes, so the captured output of a `vm_call`
is more than one line. Each dispatcher method also prints a prefixed status line,
and the SwiftUI layer scans the output's lines for that prefix:

| call | status line |
|---|---|
| `connect` | `Connected; RX value_handle bound` on success |
| `face_toggle` | `face:smile` / `face:joy` |
| `led_toggle` | `led:on:<color>` / `led:off` |
| `head_sweep` | `head:done` |

`connect` blocks the VM thread for the scan (10 s) and `head_sweep` for about
1.8 s, so both are single-flight in the UI.
```

Create `examples/watchos/stackchan/README_jp.md`:

```markdown
# Watch Stack-chan

watchOS単体で動くStack-chan操作アプリ。PicoRuby VMがApple Watch上で動き、
picoruby-bleのcentralロールをCoreBluetooth経由で直接駆動する。iPhoneのcompanion
アプリは無い。[`../../ios/stackchan`](../../ios/stackchan) のsubsetで、操作は3つ。

- **Face** — たのしそうな顔2パターン（`smile` / `joy`）をトグル
- **LED** — ランダムな色でblink開始、もう一度で停止
- **ぐるっと** — 1タップで 左 → 右 → 上 → ニュートラル

speak（字幕 + mu-law音声）とtorque、touchイベントはこのexampleのスコープ外。
それらはiOS版が持つ。

## なぜforkにwatchOS向けの変更が要るのか

watchOSは `CBPeripheralManager` / `CBMutableService` / `CBMutableCharacteristic`
の初期化子を `API_UNAVAILABLE` と宣言しているため、picoruby-bleのDarwin portは
peripheralバックエンドをwatchOS向けにコンパイルできない。`bash0C7/picoruby` の
`port-darwin` では `PicoBLEPeripheral.swift` を `#if !os(watchOS)` で囲い、
`pble_peripheral_*` のexportをno-op stubにしてある — `ble_peripheral.c` は
watchOSでもアーカイブに入りこれらを参照するので、ロールが無くてもシンボルは
必要になる。centralロールはwatchOSで完全に利用できる。

## 実機なしでワイヤ形式を検証する

フレームエンコーダは素のRubyなので、host CRubyは縮小PicoRuby VMとbyte単位で
同じフレームを作る。

```
ruby examples/watchos/stackchan/test_frames.rb   # 全部 PASS
```

## Simulator

```
rake watchos:stackchan:all     # lib -> gen -> build -> run
```

SimulatorにはBluetoothの無線が無いので、**Connectが「not found」で終わるのが
正しい挙動**。Simulatorで実証できるのは、VMがbootすること、`app.rb` がアプリ内で
コンパイルされること、各コントロールがVMへ届くこと。VMの出力はこれで読む。

```
UDID=$(xcrun simctl list devices available | grep -m1 "Apple Watch" | grep -o '[0-9A-F-]\{36\}')
xcrun simctl spawn "$UDID" log show --last 5m \
  --predicate 'eventMessage CONTAINS "WatchStackchan"' --style compact
```

## 実機のApple Watch

```
rake watchos:stackchan:device:lib     # arm64_32 の libmruby.a（BLE込み）
rake watchos:stackchan:device:check   # 署名なしでgeneric watch向けにリンク（実機不要）
rake watchos:stackchan:device:all     # lib -> gen -> build -> run（ペアリング済みの接続中の実機が要る）
```

## UIがVMの出力をどう読むか

`app.rb` は書き込んだBLEフレームを毎回echoするので、`vm_call` のcaptured output
は1行ではない。各dispatcherメソッドはprefix付きの状態行も出し、SwiftUI層は
出力の各行からそのprefixを探す。

| call | 状態行 |
|---|---|
| `connect` | 成功時 `Connected; RX value_handle bound` |
| `face_toggle` | `face:smile` / `face:joy` |
| `led_toggle` | `led:on:<color>` / `led:off` |
| `head_sweep` | `head:done` |

`connect` はスキャンの間（10秒）、`head_sweep` は約1.8秒、VMスレッドをブロック
するので、UI側で両方single-flightにしてある。
```

- [ ] **Step 5: repo 直下の README を更新**

両ファイルの3箇所に手を入れる。既存行は書き換えず、追加だけする。

**`README.md`** — example一覧のテーブルで、`watchos/led-toggle` の行の直後に足す。

```
| [watchos/stackchan](examples/watchos/stackchan/README.md) | `watchos:stackchan` | the Stack-chan controller on the wrist: a BLE central in Ruby, watch-only |
```

ディレクトリ図のRakefile行を書き換える。

変更前:
```
                         watchos:led:* / determinism:* / clean / clobber
```
変更後:
```
                         watchos:<example>:* / determinism:* / clean / clobber
```

ディレクトリ図のexamples節を書き換える。

変更前:
```
    watchos/led-toggle/  the watchOS example
```
変更後:
```
    watchos/<name>/      SwiftUI app + app.rb, watch-only
```

**`README_jp.md`** — 同じ3箇所。テーブル行:

```
| [watchos/stackchan](examples/watchos/stackchan/README_jp.md) | `watchos:stackchan` | 腕の上のStack-chan操作アプリ。RubyのBLEセントラル、watch単体 |
```

Rakefile行:

変更前:
```
                         watchos:led:* / determinism:* / clean / clobber
```
変更後:
```
                         watchos:<example>:* / determinism:* / clean / clobber
```

examples節:

変更前:
```
    watchos/led-toggle/  watchOS example
```
変更後:
```
    watchos/<name>/      SwiftUIアプリ + app.rb、watch単体
```

- [ ] **Step 6: 追記が反映されたことを確認**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
grep -n "watchos/stackchan\|watchos:stackchan" README.md README_jp.md
```

Expected: 両ファイルに追記した行が出る。

- [ ] **Step 7: rake task 一覧が揃っていることを確認**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
rake -T watchos
```

Expected: `watchos:led:*` と `watchos:stackchan:*` が対称に並ぶ。stackchan側は
`lib` / `gen` / `build` / `run` / `all` / `device:lib` / `device:build` / `device:check` / `device:run` / `device:all` の10個。

- [ ] **Step 8: Commit**

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-darwin
git add examples/watchos/stackchan/README.md examples/watchos/stackchan/README_jp.md \
        README.md README_jp.md
git commit -F - <<'EOF'
docs(watch-stackchan): example READMEs and repo README entries

Records why the fork carries a watchOS change (CBPeripheralManager is
unavailable there, but ble_peripheral.c still references the exports), and
that a Simulator Connect ending in "not found" is the correct behaviour
because the Simulator has no radio.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01CoEkzNECosgLMsFZJfVrZ7
EOF
```

---

## この計画の外に残るもの

計画完了時点で未検証のまま残り、実機が手に入ってから確かめる項目。**完了報告ではこれらを「未検証」と明記すること。**

1. **実機Apple Watch + 実Stack-chanでのBLE接続と各操作。** Simulatorでは無線が無いため、`RealBleLink` のスキャン・接続・NUS RX bind・フレーム書き込みの経路は一度も実行されない。`rake watchos:stackchan:device:all` は実機接続後に走らせる
2. **`SCAN_TIMEOUT_MS = 10000` が妥当かどうか。** watchOSのサスペンド挙動は実機でしか出ない。10秒で足りなければ `WKExtendedRuntimeSession` の導入を検討する（specの未解決リスク3）
3. **watchOSでのBluetooth権限プロンプトの出方**（watch上か、iPhone側か）（specの未解決リスク4）
4. **実機でのHEAP_SIZEの妥当性。** Simulatorはメモリ制約が実機と異なるので、Task 6 Step 5の判断は実機で再確認が要る
5. **forkのpush。** Task 1 Step 8のcommitはlocalのまま。pushはuser承認が要る

**mergeは実機動作確認が完了してから。** それまでmergeの提案自体をしない。
