# watchOS LED Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `examples/watch-led-toggle/` として PicoRuby 駆動の watchOS アプリを追加する。画面中央に 🔴 を表示し、タップで 🔵 ↔ 🔴 をトグルする。

**Architecture:** darwin port を watchsimulator/watchos SDK に向けて libmruby.a をビルド（新規 port 不要）。`$app = LEDApp.new` を boot 時に評価し、`vm_call("tick","")` が現在色を stdout に出力、`vm_call("toggle","")` が反転後の色を stdout に出力。SwiftUI は serial DispatchQueue でのみ VM を呼ぶ。

**Tech Stack:** PicoRuby (darwin port), xcodegen, xcodebuild, SwiftUI watchOS, picoruby_bridge.c (既存)

---

## File Map

| ファイル | 操作 | 責務 |
|---------|------|------|
| `build_config/r2p2-picoruby-watchos-sim.rb` | 新規 | watchsimulator SDK 向け libmruby.a |
| `build_config/r2p2-picoruby-watchos-device.rb` | 新規 | watchos SDK 向け libmruby.a |
| `examples/watch-led-toggle/app.rb` | 新規 | Ruby: `$app = LEDApp.new`、tick/toggle |
| `examples/watch-led-toggle/project.yml` | 新規 | xcodegen watchOS ターゲット設定 |
| `examples/watch-led-toggle/Sources/App.swift` | 新規 | `@main` エントリーポイント |
| `examples/watch-led-toggle/Sources/ContentView.swift` | 新規 | 🔴/🔵 表示 + tap gesture |
| `examples/watch-led-toggle/Sources/VMExecutor.swift` | 新規 | VM スレッド管理、toggle() 公開 |
| `examples/watch-led-toggle/Sources/WatchLEDToggle-Bridging-Header.h` | 新規 | C bridge import |
| `Rakefile` | 修正 | `ios:watch:*` タスク追加 |

---

## Task 1: worktree を作成する

**Files:**
- (git worktree — ファイル変更なし)

- [ ] **Step 1: superpowers:using-git-worktrees を起動してworktreeを作成する**

  このタスク群は git worktree 内で実施する。worktree がまだなければ作成する。

  ```
  # skill を起動してブランチ名 feat/watch-led-toggle を伝える
  Skill: superpowers:using-git-worktrees
  ```

---

## Task 2: watchOS Simulator build config を作成する

**Files:**
- Create: `build_config/r2p2-picoruby-watchos-sim.rb`

- [ ] **Step 1: watchsimulator SDK が存在することを確認する**

  ```bash
  xcrun --sdk watchsimulator --show-sdk-path
  ```
  期待出力: `.../WatchSimulator26.5.sdk` のような SDK パス（エラーでないこと）

- [ ] **Step 2: ファイルを作成する**

  `build_config/r2p2-picoruby-watchos-sim.rb` を以下の内容で作成する:

  ```ruby
  # watchOS Simulator (arm64) cross-build for picoruby → libmruby.a for the
  # watchsimulator SDK. Same darwin defines as the iOS sim config; only the SDK
  # and version-min flag differ. task_hal_ios.c uses only standard POSIX/Darwin
  # APIs (clock_gettime, usleep) that are available on watchOS.

  sdk_path    = `xcrun --sdk watchsimulator --show-sdk-path`.strip
  clang       = `xcrun --sdk watchsimulator --find clang`.strip
  ar          = `xcrun --sdk watchsimulator --find ar`.strip
  watchos_min = ENV["WATCHOS_MIN"] || "11.0"

  MRuby::CrossBuild.new("watchos-sim") do |conf|
    conf.toolchain :clang

    # libm is part of libSystem on Apple platforms; not a separate library.
    conf.linker.libraries.delete("m")

    conf.cc.command       = clang
    conf.linker.command   = clang
    conf.archiver.command = ar
    conf.cc.host_command  = "clang"

    conf.cc.flags << "-arch" << "arm64"
    conf.cc.flags << "-isysroot" << sdk_path
    conf.cc.flags << "-mwatchos-simulator-version-min=#{watchos_min}"

    conf.cc.defines << "MRB_TICK_UNIT=4"
    conf.cc.defines << "MRB_TIMESLICE_TICK_COUNT=3"
    conf.cc.defines << "PICORB_ALLOC_ALIGN=8"
    conf.cc.defines << "PICORB_ALLOC_ESTALLOC"
    conf.cc.defines << "PICORB_PLATFORM_DARWIN"
    conf.cc.defines << "MRB_INT64"
    conf.cc.defines << "MRB_NO_BOXING"
    conf.cc.defines << "MRB_UTF8_STRING"

    conf.picoruby
    conf.gem core: "mruby-compiler2"
  end
  ```

- [ ] **Step 3: ビルドが通ることを確認する**

  ```bash
  MRUBY_BUILD_DIR=./build MRUBY_CONFIG=$(pwd)/build_config/r2p2-picoruby-watchos-sim.rb \
    rake -C vendor/picoruby
  ```
  期待: `build/watchos-sim/lib/libmruby.a` が生成される。

  エラーが出た場合:
  - `-mwatchos-simulator-version-min=` フラグが不明: `-target arm64-apple-watchos11.0-simulator -isysroot #{sdk_path}` で置き換える
  - `task_hal_ios.c` のコンパイルエラー: `task_hal_ios.c` で失敗するシンボルを確認し、`bridge/task_hal_watchos.c` として watchOS 対応版を作成（`usleep`→`nanosleep` 等）

- [ ] **Step 4: コミットする**

  ```bash
  git add build_config/r2p2-picoruby-watchos-sim.rb
  git commit -m "feat(watch): add watchOS Simulator PicoRuby build config"
  ```

---

## Task 3: watchOS Device build config を作成する

**Files:**
- Create: `build_config/r2p2-picoruby-watchos-device.rb`

- [ ] **Step 1: ファイルを作成する**

  ```ruby
  # watchOS device (arm64) cross-build for picoruby → libmruby.a for the
  # watchos SDK (physical Apple Watch). Mirrors the watchos-sim config with the
  # physical watchos SDK and device version-min flag.

  sdk_path    = `xcrun --sdk watchos --show-sdk-path`.strip
  clang       = `xcrun --sdk watchos --find clang`.strip
  ar          = `xcrun --sdk watchos --find ar`.strip
  watchos_min = ENV["WATCHOS_MIN"] || "11.0"

  MRuby::CrossBuild.new("watchos-device") do |conf|
    conf.toolchain :clang

    conf.linker.libraries.delete("m")

    conf.cc.command       = clang
    conf.linker.command   = clang
    conf.archiver.command = ar
    conf.cc.host_command  = "clang"

    conf.cc.flags << "-arch" << "arm64"
    conf.cc.flags << "-isysroot" << sdk_path
    conf.cc.flags << "-mwatchos-version-min=#{watchos_min}"

    conf.cc.defines << "MRB_TICK_UNIT=4"
    conf.cc.defines << "MRB_TIMESLICE_TICK_COUNT=3"
    conf.cc.defines << "PICORB_ALLOC_ALIGN=8"
    conf.cc.defines << "PICORB_ALLOC_ESTALLOC"
    conf.cc.defines << "PICORB_PLATFORM_DARWIN"
    conf.cc.defines << "MRB_INT64"
    conf.cc.defines << "MRB_NO_BOXING"
    conf.cc.defines << "MRB_UTF8_STRING"

    conf.picoruby
    conf.gem core: "mruby-compiler2"
  end
  ```

- [ ] **Step 2: コミットする**

  ```bash
  git add build_config/r2p2-picoruby-watchos-device.rb
  git commit -m "feat(watch): add watchOS device PicoRuby build config"
  ```

---

## Task 4: Rakefile に ios:watch namespace を追加する

**Files:**
- Modify: `Rakefile` (既存の `namespace :ios do` ブロック内、`namespace :vperiph` の直後に追加)

- [ ] **Step 1: Rakefile の `namespace :vperiph` の `end` 直後に以下を挿入する**

  挿入位置: `namespace :ios do` ブロック内（`namespace :vperiph do ... end` の後、`desc "Generate the Xcode project..."` の前）

  ```ruby
    namespace :watch do
      WATCH_DIR     = File.join(ROOT, "examples", "watch-led-toggle")
      WATCH_PROJ    = File.join(WATCH_DIR, "WatchLEDToggle.xcodeproj")
      WATCH_BUNDLE  = "com.bash0c7.picoruby.WatchLEDToggle"
      WATCH_VENDOR  = File.join(WATCH_DIR, "Vendor")
      WATCH_DERIVED = File.join(ROOT, "build", "watchos-app")

      desc "Cross-build libmruby.a for watchOS Simulator and stage under examples/watch-led-toggle/Vendor"
      task lib: :setup do
        stage_libmruby("r2p2-picoruby-watchos-sim.rb", "watchos-sim", WATCH_VENDOR)
      end

      namespace :device do
        desc "Cross-build libmruby.a for watchOS device and stage under examples/watch-led-toggle/Vendor"
        task lib: :setup do
          stage_libmruby("r2p2-picoruby-watchos-device.rb", "watchos-device", WATCH_VENDOR)
        end
      end

      desc "Generate the Watch LED Toggle Xcode project from project.yml"
      task :gen do
        sh "cd #{WATCH_DIR.shellescape} && xcodegen generate"
      end

      desc "Build the Watch LED Toggle app for the watchOS Simulator"
      task :build do
        sh "xcodebuild -project #{WATCH_PROJ.shellescape} " \
           "-scheme WatchLEDToggle -destination 'generic/platform=watchOS Simulator' " \
           "-derivedDataPath #{WATCH_DERIVED.shellescape} " \
           "ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build"
      end

      desc "Boot a watchOS simulator, install, and launch the Watch LED Toggle app"
      task :run do
        app = Dir.glob(File.join(WATCH_DERIVED, "Build", "Products",
                                 "*-watchsimulator", "WatchLEDToggle.app")).first
        raise "app not built; run `rake ios:watch:build`" unless app
        udid = `xcrun simctl list devices available`.lines
               .grep(/Apple Watch/).first&.match(/\(([0-9A-F-]{36})\)/)&.captures&.first
        raise "no available Apple Watch simulator" unless udid
        sh "xcrun simctl boot #{udid} 2>/dev/null; true"
        sh "open -a Simulator"
        sh "xcrun simctl install #{udid} #{app.shellescape}"
        sh "xcrun simctl launch #{udid} #{WATCH_BUNDLE}"
      end

      desc "Full Watch pipeline: lib -> gen -> build -> run"
      task all: [:lib, :gen, :build, :run]
    end
  ```

- [ ] **Step 2: rake タスク一覧が壊れていないことを確認する**

  ```bash
  rake -T ios:watch
  ```
  期待出力: `rake ios:watch:lib`, `rake ios:watch:gen`, `rake ios:watch:build`, `rake ios:watch:run`, `rake ios:watch:all` が表示される

- [ ] **Step 3: コミットする**

  ```bash
  git add Rakefile
  git commit -m "feat(watch): add ios:watch:* Rake tasks"
  ```

---

## Task 5: app.rb を作成する

**Files:**
- Create: `examples/watch-led-toggle/app.rb`

- [ ] **Step 1: ディレクトリを作成する**

  ```bash
  mkdir -p examples/watch-led-toggle/Sources
  mkdir -p examples/watch-led-toggle/Vendor/lib
  ```

- [ ] **Step 2: app.rb を作成する**

  `vm_call(vm, "tick", "")` は `$app.tick("")` を呼び stdout をキャプチャする。
  `vm_call(vm, "toggle", "")` は `$app.toggle("")` を呼び stdout をキャプチャする。
  メソッドは引数を1つ受け取る（bridge の `mrb_funcall` が1引数で呼ぶため）。

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

- [ ] **Step 3: コミットする**

  ```bash
  git add examples/watch-led-toggle/app.rb
  git commit -m "feat(watch): add PicoRuby LED toggle app.rb"
  ```

---

## Task 6: project.yml を作成する

**Files:**
- Create: `examples/watch-led-toggle/project.yml`

- [ ] **Step 1: project.yml を作成する**

  ```yaml
  name: WatchLEDToggle
  options:
    bundleIdPrefix: com.bash0c7.picoruby
    deploymentTarget:
      watchOS: "11.0"
  targets:
    WatchLEDToggle:
      type: application
      platform: watchOS
      sources:
        - path: Sources
        - path: app.rb
          buildPhase: resources
        - path: ../../bridge
          includes:
            - "picoruby_bridge.c"
            - "picoruby_bridge.h"
            - "task_hal_ios.c"
      settings:
        base:
          SWIFT_OBJC_BRIDGING_HEADER: Sources/WatchLEDToggle-Bridging-Header.h
          GCC_PREPROCESSOR_DEFINITIONS:
            - "$(inherited)"
            - "PICORB_ALLOC_ESTALLOC"
            - "PICORB_ALLOC_ALIGN=8"
            - "MRB_NO_BOXING"
            - "MRB_INT64"
            - "MRB_UTF8_STRING"
            - "PICORB_PLATFORM_DARWIN"
            - "MRB_TICK_UNIT=4"
            - "MRB_TIMESLICE_TICK_COUNT=3"
            - "MRB_USE_TASK_SCHEDULER=1"
            - "MRB_USE_VM_SWITCH_DISPATCH=1"
            - "MRB_CONSTRAINED_BASELINE_PROFILE=1"
            - "MRB_HEAP_PAGE_SIZE=128"
          HEADER_SEARCH_PATHS:
            - "$(SRCROOT)/../../vendor/picoruby/include"
            - "$(SRCROOT)/../../vendor/picoruby/mrbgems/mruby-compiler2/include"
            - "$(SRCROOT)/../../vendor/picoruby/mrbgems/mruby-compiler2/lib/prism/include"
            - "$(SRCROOT)/../../vendor/picoruby/mrbgems/picoruby-mruby/lib/mruby/include"
            - "$(SRCROOT)/../../vendor/picoruby/mrbgems/picoruby-mruby/include"
            - "$(SRCROOT)/../../build/watchos-sim/include"
            - "$(SRCROOT)/../../build/watchos-device/include"
            - "$(SRCROOT)/../../vendor/picoruby/mrbgems/picoruby-mruby/lib/mruby/mrbgems/mruby-task/include"
            - "$(SRCROOT)/../../bridge"
          LIBRARY_SEARCH_PATHS:
            - "$(SRCROOT)/Vendor/lib"
          OTHER_LDFLAGS:
            - "-lmruby"
          GENERATE_INFOPLIST_FILE: "YES"
          INFOPLIST_KEY_WKApplication: "YES"
          TARGETED_DEVICE_FAMILY: "4"
          PRODUCT_BUNDLE_IDENTIFIER: com.bash0c7.picoruby.WatchLEDToggle
          CODE_SIGN_STYLE: Automatic
          DEVELOPMENT_TEAM: SM5792D355
  ```

- [ ] **Step 2: コミットする**

  ```bash
  git add examples/watch-led-toggle/project.yml
  git commit -m "feat(watch): add xcodegen project.yml for watchOS"
  ```

---

## Task 7: Swift ソースを作成する

**Files:**
- Create: `examples/watch-led-toggle/Sources/WatchLEDToggle-Bridging-Header.h`
- Create: `examples/watch-led-toggle/Sources/App.swift`
- Create: `examples/watch-led-toggle/Sources/VMExecutor.swift`
- Create: `examples/watch-led-toggle/Sources/ContentView.swift`

- [ ] **Step 1: Bridging header を作成する**

  `examples/watch-led-toggle/Sources/WatchLEDToggle-Bridging-Header.h`:
  ```c
  #import "picoruby_bridge.h"
  ```

- [ ] **Step 2: App.swift を作成する**

  `examples/watch-led-toggle/Sources/App.swift`:
  ```swift
  import SwiftUI

  @main
  struct WatchLEDToggleApp: App {
      var body: some Scene {
          WindowGroup {
              ContentView()
          }
      }
  }
  ```

- [ ] **Step 3: VMExecutor.swift を作成する**

  `vm_call` は `$app.method(arg)` を呼び、stdout をキャプチャして返す。
  `tick` は `print @state` で "red"/"blue" を出力。
  `toggle` は反転後に `print @state` で出力。
  VM スレッドは serial queue で単一スレッド制約を守る。

  `examples/watch-led-toggle/Sources/VMExecutor.swift`:
  ```swift
  import Foundation

  final class VMExecutor {
      static let shared = VMExecutor()

      private let queue = DispatchQueue(label: "com.bash0c7.watch.vm")
      private var vm: UnsafeMutableRawPointer?
      private var timer: DispatchSourceTimer?
      var onColorChange: ((String) -> Void)?

      private init() {}

      func start(bootSource: String, onColor: @escaping (String) -> Void) {
          self.onColorChange = onColor
          queue.async {
              guard let handle = bootSource.withCString({ vm_open($0) }) else {
                  NSLog("[WatchLEDToggle] vm_open returned NULL")
                  return
              }
              self.vm = handle
              NSLog("[WatchLEDToggle] VM opened")
              self.startTick()
          }
      }

      func toggle() {
          queue.async { [weak self] in
              guard let self = self, let vm = self.vm else { return }
              let out = "toggle".withCString { m in
                  "".withCString { a in vm_call(vm, m, a) }
              }
              let color = out.map {
                  String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines)
              } ?? ""
              if let o = out { free(o) }
              guard !color.isEmpty else { return }
              DispatchQueue.main.async { self.onColorChange?(color) }
          }
      }

      private func startTick() {
          let t = DispatchSource.makeTimerSource(queue: queue)
          t.schedule(deadline: .now() + 0.1, repeating: 0.1)
          t.setEventHandler { [weak self] in
              guard let self = self, let vm = self.vm else { return }
              let out = "tick".withCString { m in
                  "".withCString { a in vm_call(vm, m, a) }
              }
              let color = out.map {
                  String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines)
              } ?? ""
              if let o = out { free(o) }
              guard color == "red" || color == "blue" else { return }
              DispatchQueue.main.async { self.onColorChange?(color) }
          }
          t.resume()
          self.timer = t
      }
  }
  ```

- [ ] **Step 4: ContentView.swift を作成する**

  `examples/watch-led-toggle/Sources/ContentView.swift`:
  ```swift
  import SwiftUI

  struct ContentView: View {
      @State private var color = "red"

      var body: some View {
          Text(color == "red" ? "🔴" : "🔵")
              .font(.system(size: 80))
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .onTapGesture {
                  VMExecutor.shared.toggle()
              }
              .onAppear {
                  boot()
              }
      }

      private func boot() {
          guard let url = Bundle.main.url(forResource: "app", withExtension: "rb"),
                let src = try? String(contentsOf: url, encoding: .utf8) else {
              NSLog("[WatchLEDToggle] could not read app.rb")
              return
          }
          VMExecutor.shared.start(bootSource: src) { c in
              color = c
          }
      }
  }
  ```

- [ ] **Step 5: コミットする**

  ```bash
  git add examples/watch-led-toggle/Sources/
  git commit -m "feat(watch): add SwiftUI sources for watchOS LED toggle"
  ```

---

## Task 8: ビルドパイプラインを通す

**Files:**
- (既存ファイルの確認のみ)

- [ ] **Step 1: `rake ios:watch:lib` で libmruby.a をビルド・ステージングする**

  ```bash
  rake ios:watch:lib
  ```
  期待: `examples/watch-led-toggle/Vendor/lib/libmruby.a` が生成される。

  失敗した場合は Task 2 Step 3 の代替フラグ対応を行う。

- [ ] **Step 2: `rake ios:watch:gen` で Xcode プロジェクトを生成する**

  ```bash
  rake ios:watch:gen
  ```
  期待: `examples/watch-led-toggle/WatchLEDToggle.xcodeproj` が生成される。

  失敗した場合: project.yml の `type: application` が watchOS で正しいか確認する。
  エラーメッセージを読んで必要なキーを追加する。

- [ ] **Step 3: `rake ios:watch:build` でシミュレーター向けにビルドする**

  ```bash
  rake ios:watch:build
  ```
  期待: `BUILD SUCCEEDED` が出力される。

  よくある失敗と対応:
  - `libmruby.a` が見つからない → `LIBRARY_SEARCH_PATHS` が正しいか確認
  - `picoruby_bridge.h` が見つからない → `HEADER_SEARCH_PATHS` の `bridge` パスを確認
  - `-mwatchos-simulator-version-min` 未知フラグ → Task 2 Step 3 の代替フラグに切り替え
  - `INFOPLIST_KEY_WKApplication` 不明 → xcodegen のバージョンによっては `infoPlist.properties` セクションに移す

- [ ] **Step 4: `rake ios:watch:run` でシミュレーター起動・インストール・ランする**

  ```bash
  rake ios:watch:run
  ```
  期待: Simulator が起動し、Watch 画面中央に 🔴 が表示される。タップで 🔵 ↔ 🔴 がトグルする。

- [ ] **Step 5: 動作確認後にコミットする（生成ファイルを除外する）**

  xcodeproj と DerivedData は gitignore 済みなので staging 不要。
  Vendor/lib/libmruby.a は gitignore されているか確認:

  ```bash
  git status examples/watch-led-toggle/
  ```

  未追跡ファイルが残っていれば `.gitignore` に追記してからコミット:
  ```bash
  git add examples/watch-led-toggle/
  git commit -m "feat(watch): wire up watchOS LED toggle example end-to-end"
  ```
