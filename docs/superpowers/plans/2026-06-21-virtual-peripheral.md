# Virtual BLE Peripheral example — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a third R2P2-iOS example, `examples/virtual-peripheral/`: a configurable virtual BLE *peripheral* test stub whose GATT profile and per-event behavior are defined in PicoRuby (`app.rb`), with Swift only as the CoreBluetooth radio + C bridge + a read-only scrolling log UI.

**Architecture:** A persistent PicoRuby VM owns the device behavior. The Swift `CBPeripheralManager` asks the VM for the GATT profile (a serialized string), builds the service tree, advertises `PBLE-TEST`, and forwards every central event (read / write / subscribe) to the VM via `vm_call`. Because the bridge's `vm_call` returns **captured stdout** (not the method's return value), every Ruby handler `print`s its result; Swift reads that stdout. Characteristic values cross the bridge as **lowercase hex ASCII** (the C string return cannot carry NUL bytes). The example reuses the base reduced-VM build-config — it does **not** use picoruby-ble at all.

**Tech Stack:** PicoRuby (reduced VM: prism, no Regexp/`Array#pack`/`defined?`), SwiftUI, CoreBluetooth (`CBPeripheralManager`), the existing `bridge/picoruby_bridge.c` persistent-VM API (`vm_open`/`vm_call`/`vm_close`), xcodegen, rake.

---

## Load-bearing context (read before starting)

- **`vm_call` returns captured stdout+stderr**, per `bridge/picoruby_bridge.h`. Handlers must `print` their protocol string. The method's return value is discarded.
- **Reduced VM surface**: no `Regexp`, no `Array#pack`, no `defined?`. Build/parse hex by hand. Stick to `String#[i,1]`, `String#ord`, `Integer#chr`, `String#index`, `>>`, `&`, `Hash`/`Array` literals, `each`, `while`, string `+`/`+=` — all proven in `examples/stackchan/app.rb`. Task 2 probes these against the real reduced VM before any device work.
- **The peripheral MUST be Swift.** The picoruby-ble Darwin port is central-only (its peripheral C functions are no-op stubs). Do **not** add peripheral support to the `bash0C7/picoruby` fork / darwin-port worktree — that is a cross-repo responsibility violation. All Swift lives in this example's `Sources/`.
- **Simulator has no BLE.** `CBPeripheralManager` reports `.unsupported` on the Simulator, so advertising/connect can only be verified on a physical device. The Simulator verifies: builds, launches, VM opens, profile parses, UI renders, and the manager logs its (unsupported) state. The physical-device BLE round-trip is the hardware-gated final step and is NOT executed by this plan.
- **Copy patterns, don't invent:** `examples/repl/` is the base-config (no-BLE) template; `examples/stackchan/Sources/VMExecutor.swift` is the persistent-VM owner to copy.

## File structure

| File | Responsibility |
|---|---|
| `examples/virtual-peripheral/app.rb` | PicoRuby brain: `Hex` helpers, two GATT profiles as data, `VirtualPeripheral` dispatcher (`profile`/`on_read`/`on_write`/`on_subscribe`/`on_unsubscribe`/`tick`), `$app`. |
| `examples/virtual-peripheral/test_profile.rb` | Host CRuby test: drives `$app`/`VirtualPeripheral` with captured stdout, asserts protocol strings for both profiles. |
| `examples/virtual-peripheral/Sources/App.swift` | SwiftUI `@main` entry. |
| `examples/virtual-peripheral/Sources/VMExecutor.swift` | Persistent VM owner (serial queue), with an added synchronous `callSync`. |
| `examples/virtual-peripheral/Sources/PeripheralManager.swift` | `CBPeripheralManager` radio: build GATT from VM profile, advertise, route events to VM, notify; `Data`↔hex. |
| `examples/virtual-peripheral/Sources/ContentView.swift` | Read-only scrolling log + defensive keyboard-dismiss. |
| `examples/virtual-peripheral/Sources/VirtualPeripheral-Bridging-Header.h` | `#import "picoruby_bridge.h"`. |
| `examples/virtual-peripheral/project.yml` | xcodegen config (base ABI defines, app.rb resource, BLE Info.plist keys). |
| `Rakefile` | Add `namespace :vperiph` under `namespace :ios` (`lib`/`gen`/`build`/`run`/`all` + `device:*`). |

---

### Task 1: PicoRuby brain (`app.rb`) + host test

**Files:**
- Create: `examples/virtual-peripheral/app.rb`
- Create: `examples/virtual-peripheral/test_profile.rb`

- [ ] **Step 1: Write the failing host test**

Create `examples/virtual-peripheral/test_profile.rb`:

```ruby
# Host CRuby test for the virtual-peripheral brain. vm_call returns captured
# stdout, so each handler prints its protocol string; here we capture stdout the
# same way. No BLE / Swift — verifies the Ruby protocol logic only. The reduced
# PicoRuby VM is verified separately by the host-libmruby probe.
require "stringio"
require_relative "app"

def capture
  old = $stdout
  $stdout = StringIO.new
  yield
  $stdout.string
ensure
  $stdout = old
end

def assert_eq(actual, expected, msg)
  if actual == expected
    puts "ok - #{msg}"
  else
    puts "FAIL - #{msg}\n  expected: #{expected.inspect}\n  actual:   #{actual.inspect}"
    $failed = true
  end
end

$failed = false

# --- Heart Rate profile ---
hr = VirtualPeripheral.new(HEART_RATE_PROFILE)
assert_eq(capture { hr.profile("") },
          "NAME PBLE-TEST\nSERVICE 180d\nCHAR 2a37 n\nCHAR 2a38 r\nCHAR 2a39 w\n",
          "heart-rate profile serialization")
assert_eq(capture { hr.on_read("2a38") },
          "01|READ  Body Sensor Location -> Wrist (0x01)",
          "body sensor location read")
assert_eq(capture { hr.tick("") }, "", "tick with no subscriber is silent")
hr.on_subscribe("2a37")
assert_eq(capture { hr.tick("") },
          "2a37:003d|NOTIFY Heart Rate Measurement -> 61 bpm",
          "first heart-rate notify is 61 bpm (0x3d)")

# --- NUS profile ---
nus = VirtualPeripheral.new(NUS_PROFILE)
rx = VirtualPeripheral::NUS_RX
tx = VirtualPeripheral::NUS_TX
assert_eq(capture { nus.on_write("#{rx}|#{Hex.ascii_to_hex("<F:2>\n")}") },
          "#{tx}:2e|WRITE RX <- <F:2>",
          "NUS frame write auto-ACKs '.' (0x2e) on TX")
assert_eq(capture { nus.on_write("#{rx}|#{Hex.ascii_to_hex("<read:pos>\n")}") },
          "#{tx}:#{Hex.ascii_to_hex("<YL_actual:0,PU_actual:50>\n")}|WRITE RX <- <read:pos>",
          "read:pos write replies with a detail frame")

exit(1) if $failed
puts "all virtual-peripheral profile tests passed"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd examples/virtual-peripheral && ruby test_profile.rb`
Expected: FAIL — `cannot load such file -- .../app` (app.rb does not exist yet).

- [ ] **Step 3: Write `app.rb`**

Create `examples/virtual-peripheral/app.rb`:

```ruby
# Virtual BLE peripheral — the PicoRuby brain. The Swift CBPeripheralManager
# (Sources/PeripheralManager.swift) is only the radio: at power-on it asks this
# object for the GATT profile to publish, then forwards every central event
# (read, write, subscribe) here and applies whatever this object emits. ALL
# device behavior — which services exist, what a read returns, how a write is
# answered, what gets notified — is decided here, in Ruby. That is the point of
# this example: a BLE peripheral app built PicoRuby-first.
#
# The bridge's vm_call returns CAPTURED STDOUT (not the return value), so every
# handler `print`s its protocol string. Characteristic values cross the bridge
# as lowercase hex ASCII (the C-string return cannot carry NUL bytes). The
# reduced PicoRuby VM has no Regexp / Array#pack / defined?, so hex is built and
# parsed by hand below.

module Hex
  DIGITS = "0123456789abcdef"

  # Integer (0..255) -> 2 lowercase hex chars.
  def self.byte_to_hex(b)
    DIGITS[b >> 4, 1] + DIGITS[b & 15, 1]
  end

  # ASCII String -> lowercase hex (2 chars per byte).
  def self.ascii_to_hex(str)
    out = ""
    i = 0
    while i < str.length
      out += byte_to_hex(str[i, 1].ord)
      i += 1
    end
    out
  end

  # 1 lowercase hex char -> its 0..15 value.
  def self.nibble(c)
    DIGITS.index(c)
  end

  # lowercase hex String -> ASCII String.
  def self.to_ascii(hex)
    out = ""
    i = 0
    n = hex.length
    while i + 2 <= n
      out += (nibble(hex[i, 1]) * 16 + nibble(hex[i + 1, 1])).chr
      i += 2
    end
    out
  end
end

# ---- GATT profiles (data) ---------------------------------------------------
# A profile is a Hash: "name" + "services" => [[service_uuid, [[char_uuid,
# props], ...]], ...]. UUIDs: 16-bit as 4 lowercase hex chars ("180d"); 128-bit
# as the full lowercase dashed string. props is any of "r"/"w"/"n".
DEVICE_NAME = "PBLE-TEST"

HEART_RATE_PROFILE = {
  "name" => DEVICE_NAME,
  "services" => [
    ["180d", [
      ["2a37", "n"],   # Heart Rate Measurement (notify)
      ["2a38", "r"],   # Body Sensor Location (read)
      ["2a39", "w"],   # Heart Rate Control Point (write)
    ]],
  ],
}

NUS_PROFILE = {
  "name" => DEVICE_NAME,
  "services" => [
    ["6e400001-b5a3-f393-e0a9-e50e24dcca9e", [
      ["6e400002-b5a3-f393-e0a9-e50e24dcca9e", "w"],  # RX: central writes here
      ["6e400003-b5a3-f393-e0a9-e50e24dcca9e", "n"],  # TX: we notify here
    ]],
  ],
}

# Choose the profile to publish, then relaunch. No runtime switch (YAGNI).
ACTIVE_PROFILE = HEART_RATE_PROFILE

# The dispatcher the bridge calls: vm_call(method, arg) invokes one of these
# with a single String arg. Each method prints its protocol string.
class VirtualPeripheral
  HR_MEASUREMENT = "2a37"
  HR_BODY_LOC    = "2a38"
  HR_CONTROL_PT  = "2a39"
  NUS_RX = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
  NUS_TX = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"

  def initialize(profile)
    @profile = profile
    @subscribed = {}   # char_uuid => true/false
    @bpm = 60
  end

  # Serialize the active profile for Swift to build the GATT tree. Lines:
  # "NAME <name>", "SERVICE <uuid>", "CHAR <uuid> <props>".
  def profile(arg = nil)
    out = "NAME #{@profile["name"]}\n"
    @profile["services"].each do |svc|
      out += "SERVICE #{svc[0]}\n"
      svc[1].each do |ch|
        out += "CHAR #{ch[0]} #{ch[1]}\n"
      end
    end
    print out
  end

  # arg: "<char_uuid>". Prints "<value_hex>|<log_line>".
  def on_read(arg)
    if arg == HR_BODY_LOC
      print "01|READ  Body Sensor Location -> Wrist (0x01)"
    else
      print "|READ  #{arg} -> (empty)"
    end
  end

  # arg: "<char_uuid>|<value_hex>". Prints
  # "<resp_char_uuid>:<resp_hex>|<log_line>" (head empty if no response).
  def on_write(arg)
    bar  = arg.index("|")
    uuid = arg[0, bar]
    hex  = arg[bar + 1, arg.length]
    if uuid == NUS_RX
      frame = Hex.to_ascii(hex)
      disp = frame
      disp = frame[0, frame.length - 1] if frame.length > 0 && frame[frame.length - 1, 1] == "\n"
      reply = (frame == "<read:pos>\n") ? "<YL_actual:0,PU_actual:50>\n" : "."
      print "#{NUS_TX}:#{Hex.ascii_to_hex(reply)}|WRITE RX <- #{disp}"
    elsif uuid == HR_CONTROL_PT
      print "|WRITE Heart Rate Control Point <- 0x#{hex} (accepted)"
    else
      print "|WRITE #{uuid} <- 0x#{hex}"
    end
  end

  # arg: "<char_uuid>".
  def on_subscribe(arg)
    @subscribed[arg] = true
    print "SUBSCRIBE #{arg}"
  end

  def on_unsubscribe(arg)
    @subscribed[arg] = false
    print "UNSUBSCRIBE #{arg}"
  end

  # Push periodic notifications for subscribed notify characteristics. Prints
  # zero or more "<char_uuid>:<value_hex>|<log_line>" lines, or nothing.
  def tick(arg = nil)
    return unless @subscribed[HR_MEASUREMENT]
    @bpm += 1
    @bpm = 60 if @bpm > 90
    # Heart Rate Measurement: flags byte 0x00 (uint8 bpm) + bpm byte.
    value_hex = "00" + Hex.byte_to_hex(@bpm)
    print "#{HR_MEASUREMENT}:#{value_hex}|NOTIFY Heart Rate Measurement -> #{@bpm} bpm"
  end
end

$app = VirtualPeripheral.new(ACTIVE_PROFILE)
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd examples/virtual-peripheral && ruby test_profile.rb`
Expected: every line `ok - ...`, final `all virtual-peripheral profile tests passed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add examples/virtual-peripheral/app.rb examples/virtual-peripheral/test_profile.rb
git commit -m "feat(vperiph): PicoRuby virtual-peripheral brain + host profile tests"
```

---

### Task 2: Reduced-VM probe of `app.rb`

Confirms `app.rb` runs on the **reduced** PicoRuby VM (the host CRuby test uses full Ruby and cannot catch a missing `String#index`, `Integer#chr`, bit op, etc.). Mirrors the `rake smoke` flags and links the host `libmruby.a`.

**Files:**
- Create (throwaway, outside the repo): `/tmp/vperiph_probe.c`

- [ ] **Step 1: Refresh the host build (presym headers)**

Run: `rake smoke`
Expected: ends with the smoke test printing its output and exiting 0. (This rebuilds `build/host/include` presym headers; a stale `presym/id.h` causes `use of empty enum`.)

- [ ] **Step 2: Write the probe**

Create `/tmp/vperiph_probe.c`:

```c
#include <stdio.h>
#include <stdlib.h>
#include "picoruby_bridge.h"

/* Boot examples/virtual-peripheral/app.rb in the persistent reduced VM and call
 * the bridge seam the Swift radio uses. Confirms app.rb runs on the reduced VM
 * (Hex helpers, profiles, dispatcher) and the protocol strings come back. */
static char *slurp(const char *path) {
  FILE *f = fopen(path, "rb");
  if (!f) { perror(path); exit(2); }
  fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
  char *buf = malloc(n + 1);
  fread(buf, 1, n, f); buf[n] = 0; fclose(f);
  return buf;
}
static void call(void *vm, const char *m, const char *a) {
  char *out = vm_call(vm, m, a);
  printf("call %s(%s) ->\n%s\n----\n", m, a ? a : "", out ? out : "(NULL)");
  free(out);
}
int main(int argc, char **argv) {
  char *boot = slurp(argv[1]);
  void *vm = vm_open(boot);
  if (!vm) { printf("FAIL: vm_open returned NULL (app.rb failed to boot)\n"); return 1; }
  printf("OK: vm_open succeeded\n");
  call(vm, "profile", "");
  call(vm, "on_read", "2a38");
  call(vm, "on_subscribe", "2a37");
  call(vm, "tick", "");
  /* NUS RX write of "<F:2>\n" = 3c 46 3a 32 3e 0a */
  call(vm, "on_write", "6e400002-b5a3-f393-e0a9-e50e24dcca9e|3c463a323e0a");
  vm_close(vm);
  free(boot);
  return 0;
}
```

- [ ] **Step 3: Compile and run the probe**

Run (zsh — note `${=defines}` / `${=includes}` so the flag strings word-split):

```bash
cd /Users/bash/dev/src/github.com/bash0C7/R2P2-iOS
defines="-DPICORB_ALLOC_ESTALLOC -DPICORB_ALLOC_ALIGN=8 -DMRB_NO_BOXING -DMRB_INT64 -DMRB_UTF8_STRING -DPICORB_PLATFORM_DARWIN -DMRB_TICK_UNIT=4 -DMRB_TIMESLICE_TICK_COUNT=3 -DMRB_USE_TASK_SCHEDULER=1 -DMRB_USE_VM_SWITCH_DISPATCH=1"
includes="-I vendor/picoruby/include -I vendor/picoruby/mrbgems/mruby-compiler2/include -I vendor/picoruby/mrbgems/mruby-compiler2/lib/prism/include -I vendor/picoruby/mrbgems/picoruby-mruby/lib/mruby/include -I vendor/picoruby/mrbgems/picoruby-mruby/include -I build/host/include -I vendor/picoruby/mrbgems/picoruby-mruby/lib/mruby/mrbgems/mruby-task/include -I bridge"
clang ${=defines} ${=includes} /tmp/vperiph_probe.c bridge/picoruby_bridge.c build/host/lib/libmruby.a -o /tmp/vperiph_probe
/tmp/vperiph_probe examples/virtual-peripheral/app.rb
```

Expected output (no NoMethodError / backtrace anywhere):
```
OK: vm_open succeeded
call profile() ->
NAME PBLE-TEST
SERVICE 180d
CHAR 2a37 n
CHAR 2a38 r
CHAR 2a39 w
----
call on_read(2a38) ->
01|READ  Body Sensor Location -> Wrist (0x01)
----
call on_subscribe(2a37) ->
SUBSCRIBE 2a37
----
call tick() ->
2a37:003d|NOTIFY Heart Rate Measurement -> 61 bpm
----
call on_write(6e400002-b5a3-f393-e0a9-e50e24dcca9e|3c463a323e0a) ->
6e400003-b5a3-f393-e0a9-e50e24dcca9e:2e|WRITE RX <- <F:2>
----
```

- [ ] **Step 4: If the probe shows a NoMethodError / wrong output, fix `app.rb`**

Rewrite the offending helper within the reduced surface (e.g. if `String#index` is absent, replace `Hex.nibble` with a manual scan over `DIGITS`; if `Integer#chr` is absent, build via a 256-entry lookup). Re-run Task 1 Step 4 (host test) and this probe until both are clean. No code change needed if the expected output already matches.

- [ ] **Step 5: Commit (only if `app.rb` changed)**

```bash
git add examples/virtual-peripheral/app.rb
git commit -m "fix(vperiph): keep app.rb within the reduced PicoRuby VM surface"
```

(If `app.rb` was unchanged, skip — nothing to commit; the probe is throwaway.)

---

### Task 3: Swift app shell + VM owner

**Files:**
- Create: `examples/virtual-peripheral/Sources/App.swift`
- Create: `examples/virtual-peripheral/Sources/VMExecutor.swift`
- Create: `examples/virtual-peripheral/Sources/VirtualPeripheral-Bridging-Header.h`

- [ ] **Step 1: Create the bridging header**

Create `examples/virtual-peripheral/Sources/VirtualPeripheral-Bridging-Header.h`:

```c
#import "picoruby_bridge.h"
```

- [ ] **Step 2: Create the app entry**

Create `examples/virtual-peripheral/Sources/App.swift`:

```swift
import SwiftUI

@main
struct VirtualPeripheralApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

- [ ] **Step 3: Create the VM owner**

Create `examples/virtual-peripheral/Sources/VMExecutor.swift` (the stackchan owner plus a synchronous `callSync` the CoreBluetooth delegate needs):

```swift
import Foundation

// Owns the persistent PicoRuby VM. mruby is single-threaded, so vm_open /
// vm_call / vm_close MUST all run on ONE thread. This serial DispatchQueue is
// that thread. The CoreBluetooth delegate calls `callSync` (it must answer a
// central synchronously); the timer calls it for ticks. Because vm_open is
// enqueued first, every later callSync (a queue.sync) runs after the VM is open.
final class VMExecutor {
    static let shared = VMExecutor()

    private let queue = DispatchQueue(label: "com.bash0c7.vperiph.vm")
    private var vm: UnsafeMutableRawPointer?

    private init() {}

    // Open the VM with the bundled app.rb as boot source.
    func start(bootSource: String, onResult: @escaping (String) -> Void) {
        queue.async {
            guard let handle = bootSource.withCString({ vm_open($0) }) else {
                NSLog("[VirtualPeripheral] vm_open returned NULL (app.rb failed to load)")
                onResult("(VM failed to start — app.rb did not load)")
                return
            }
            self.vm = handle
            NSLog("[VirtualPeripheral] VM opened")
            onResult("VM ready")
        }
    }

    // Synchronously invoke vm_call(method, arg) on the VM thread and return its
    // captured stdout. Returns nil if the VM is not open yet.
    func callSync(_ method: String, _ arg: String) -> String? {
        queue.sync {
            guard let vm = self.vm else { return nil }
            let out = method.withCString { m in
                arg.withCString { a in vm_call(vm, m, a) }
            }
            let result = out.map { String(cString: $0) }
            if let out = out { free(out) }
            return result
        }
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add examples/virtual-peripheral/Sources/App.swift \
        examples/virtual-peripheral/Sources/VMExecutor.swift \
        examples/virtual-peripheral/Sources/VirtualPeripheral-Bridging-Header.h
git commit -m "feat(vperiph): SwiftUI app shell + persistent VM owner (callSync)"
```

(Builds are verified in Task 6 once `project.yml` and the rake tasks exist.)

---

### Task 4: CoreBluetooth peripheral radio

**Files:**
- Create: `examples/virtual-peripheral/Sources/PeripheralManager.swift`

- [ ] **Step 1: Create `PeripheralManager.swift`**

```swift
import CoreBluetooth
import Foundation

// The CoreBluetooth radio. It holds NO device logic: at power-on it loads the
// bundled app.rb into the VM, asks the VM for the GATT profile, builds the
// service tree, advertises, and forwards every central event to the VM —
// applying whatever the VM prints (a value to return, a frame to notify). All
// behavior lives in app.rb. Keyed by each characteristic's canonical lowercase
// UUID string, which is also how app.rb names them.
final class PeripheralManager: NSObject, ObservableObject, CBPeripheralManagerDelegate {
    @Published var log: String = ""

    private var manager: CBPeripheralManager!
    private var deviceName = "PBLE-TEST"
    private var chars: [String: CBMutableCharacteristic] = [:]
    private var timer: Timer?

    override init() {
        super.init()
        let boot = Self.loadAppRb()
        VMExecutor.shared.start(bootSource: boot) { [weak self] msg in
            self?.append(msg)
        }
        manager = CBPeripheralManager(delegate: self, queue: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pump()
        }
    }

    private static func loadAppRb() -> String {
        guard let url = Bundle.main.url(forResource: "app", withExtension: "rb"),
              let s = try? String(contentsOf: url, encoding: .utf8) else {
            NSLog("[VirtualPeripheral] app.rb not found in bundle")
            return "$app = Object.new"
        }
        return s
    }

    private func append(_ line: String) {
        guard !line.isEmpty else { return }
        DispatchQueue.main.async {
            self.log += (self.log.isEmpty ? "" : "\n") + line
        }
    }

    // "<value>|<log>" -> (value, log). If no "|", the whole string is the value.
    private func split(_ s: String) -> (String, String) {
        guard let bar = s.firstIndex(of: "|") else { return (s, "") }
        return (String(s[..<bar]), String(s[s.index(after: bar)...]))
    }

    // MARK: CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            append("BLE powered on; building profile")
            buildAndAdvertise()
        case .poweredOff:    append("BLE powered off")
        case .unauthorized:  append("BLE unauthorized — grant Bluetooth permission in Settings")
        case .unsupported:   append("BLE unsupported here (the Simulator has no Bluetooth radio)")
        default:             append("BLE state changed: \(peripheral.state.rawValue)")
        }
    }

    private func buildAndAdvertise() {
        guard let spec = VMExecutor.shared.callSync("profile", "") else {
            append("(VM profile unavailable)")
            return
        }
        var services: [CBMutableService] = []
        var current: CBMutableService?
        var currentChars: [CBCharacteristic] = []
        func flush() {
            if let svc = current { svc.characteristics = currentChars; services.append(svc) }
        }
        for raw in spec.split(separator: "\n") {
            let line = String(raw)
            if line.hasPrefix("NAME ") {
                deviceName = String(line.dropFirst(5))
            } else if line.hasPrefix("SERVICE ") {
                flush()
                current = CBMutableService(type: CBUUID(string: String(line.dropFirst(8))), primary: true)
                currentChars = []
            } else if line.hasPrefix("CHAR ") {
                let parts = line.dropFirst(5).split(separator: " ")
                guard parts.count == 2 else { continue }
                let uuid = String(parts[0])
                let props = String(parts[1])
                var p: CBCharacteristicProperties = []
                var a: CBAttributePermissions = []
                if props.contains("r") { p.insert(.read);   a.insert(.readable) }
                if props.contains("w") { p.insert(.write);  a.insert(.writeable) }
                if props.contains("n") { p.insert(.notify) }
                let cbuuid = CBUUID(string: uuid)
                let ch = CBMutableCharacteristic(type: cbuuid, properties: p, value: nil, permissions: a)
                chars[cbuuid.uuidString.lowercased()] = ch
                currentChars.append(ch)
            }
        }
        flush()
        for svc in services { manager.add(svc) }
        manager.startAdvertising([
            CBAdvertisementDataLocalNameKey: deviceName,
            CBAdvertisementDataServiceUUIDsKey: services.map { $0.uuid },
        ])
        append("Advertising as \"\(deviceName)\" with \(services.count) service(s)")
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        let uuid = request.characteristic.uuid.uuidString.lowercased()
        guard let resp = VMExecutor.shared.callSync("on_read", uuid) else {
            p.respond(to: request, withResult: .unlikelyError)
            return
        }
        let (hex, log) = split(resp)
        request.value = Data(hexString: hex)
        p.respond(to: request, withResult: .success)
        append(log)
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            let uuid = request.characteristic.uuid.uuidString.lowercased()
            let hex = (request.value ?? Data()).hexString
            guard let resp = VMExecutor.shared.callSync("on_write", "\(uuid)|\(hex)") else { continue }
            let (head, log) = split(resp)
            append(log)
            if !head.isEmpty, let colon = head.firstIndex(of: ":") {
                notify(uuidString: String(head[..<colon]),
                       hex: String(head[head.index(after: colon)...]))
            }
        }
        if let first = requests.first { p.respond(to: first, withResult: .success) }
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        if let log = VMExecutor.shared.callSync("on_subscribe", characteristic.uuid.uuidString.lowercased()) {
            append(log)
        }
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        if let log = VMExecutor.shared.callSync("on_unsubscribe", characteristic.uuid.uuidString.lowercased()) {
            append(log)
        }
    }

    // MARK: tick + notify

    private func pump() {
        guard let out = VMExecutor.shared.callSync("tick", ""), !out.isEmpty else { return }
        for raw in out.split(separator: "\n") {
            let (head, log) = split(String(raw))
            if let colon = head.firstIndex(of: ":") {
                notify(uuidString: String(head[..<colon]),
                       hex: String(head[head.index(after: colon)...]))
            }
            append(log)
        }
    }

    private func notify(uuidString: String, hex: String) {
        let key = CBUUID(string: uuidString).uuidString.lowercased()
        guard let ch = chars[key] else { return }
        manager.updateValue(Data(hexString: hex), for: ch, onSubscribedCentrals: nil)
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init(hexString: String) {
        var data = Data()
        var i = hexString.startIndex
        while i < hexString.endIndex {
            let j = hexString.index(i, offsetBy: 2, limitedBy: hexString.endIndex) ?? hexString.endIndex
            if let b = UInt8(hexString[i..<j], radix: 16) { data.append(b) }
            i = j
        }
        self = data
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add examples/virtual-peripheral/Sources/PeripheralManager.swift
git commit -m "feat(vperiph): CBPeripheralManager radio driven by the PicoRuby profile"
```

---

### Task 5: Read-only scrolling log UI

**Files:**
- Create: `examples/virtual-peripheral/Sources/ContentView.swift`

- [ ] **Step 1: Create `ContentView.swift`**

```swift
import SwiftUI

struct ContentView: View {
    @StateObject private var peripheral = PeripheralManager()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Virtual BLE Peripheral").font(.headline)
            Text("Advertising a PicoRuby-defined GATT profile. Connect from a BLE central; activity streams below.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(peripheral.log.isEmpty ? "—" : peripheral.log)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("LOGEND")
                }
                .frame(maxHeight: .infinity)
                .border(.gray)
                .onChange(of: peripheral.log) { _, _ in
                    proxy.scrollTo("LOGEND", anchor: .bottom)
                }
            }
        }
        .padding()
        // The log is read-only, so the software keyboard never appears. These
        // are defensive: if any focusable control is ever added, a tap anywhere
        // or the keyboard "Done" button dismisses it so it can't cover the log.
        .contentShape(Rectangle())
        .onTapGesture { focused = false }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = false }
            }
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add examples/virtual-peripheral/Sources/ContentView.swift
git commit -m "feat(vperiph): read-only scrolling activity log UI"
```

---

### Task 6: Build wiring (project.yml + Rakefile) and Simulator verification

**Files:**
- Create: `examples/virtual-peripheral/project.yml`
- Modify: `Rakefile` (add `namespace :vperiph` inside `namespace :ios`)

- [ ] **Step 1: Create `project.yml`**

Create `examples/virtual-peripheral/project.yml` (the repl base config + an `app.rb` resource + peripheral Info.plist keys):

```yaml
name: VirtualPeripheral
options:
  bundleIdPrefix: com.bash0c7.picoruby
  deploymentTarget:
    iOS: "17.0"
targets:
  VirtualPeripheral:
    type: application
    platform: iOS
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
        SWIFT_OBJC_BRIDGING_HEADER: Sources/VirtualPeripheral-Bridging-Header.h
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
          - "$(SRCROOT)/../../build/ios-sim/include"
          - "$(SRCROOT)/../../build/ios-device/include"
          - "$(SRCROOT)/../../vendor/picoruby/mrbgems/picoruby-mruby/lib/mruby/mrbgems/mruby-task/include"
          - "$(SRCROOT)/../../bridge"
        LIBRARY_SEARCH_PATHS:
          - "$(SRCROOT)/Vendor/lib"
        OTHER_LDFLAGS:
          - "-lmruby"
        GENERATE_INFOPLIST_FILE: "YES"
        INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription: "Advertise a virtual BLE peripheral so a central (e.g. the PC stackchan) can connect for testing."
        INFOPLIST_KEY_NSBluetoothPeripheralUsageDescription: "Advertise a virtual BLE peripheral so a central can connect for testing."
        TARGETED_DEVICE_FAMILY: "1,2"
        PRODUCT_BUNDLE_IDENTIFIER: com.bash0c7.picoruby.VirtualPeripheral
        CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: SM5792D355
```

- [ ] **Step 2: Add the rake namespace**

In `Rakefile`, inside `namespace :ios do`, after the `namespace :stackchan do ... end` block (i.e. immediately before the top-level `desc "Generate the Xcode project from project.yml"` / `task :gen` near line 228), insert:

```ruby
  namespace :vperiph do
    VPERIPH_DIR     = File.join(ROOT, "examples", "virtual-peripheral")
    VPERIPH_PROJ    = File.join(VPERIPH_DIR, "VirtualPeripheral.xcodeproj")
    VPERIPH_BUNDLE  = "com.bash0c7.picoruby.VirtualPeripheral"
    VPERIPH_VENDOR  = File.join(VPERIPH_DIR, "Vendor")
    VPERIPH_DERIVED = File.join(ROOT, "build", "ios-vperiph-app")
    VPERIPH_DEVICE_DERIVED = File.join(ROOT, "build", "ios-vperiph-app-device")

    desc "Cross-build libmruby.a (Simulator, base reduced VM) and stage under examples/virtual-peripheral/Vendor"
    task lib: :setup do
      stage_libmruby("r2p2-picoruby-ios-sim.rb", "ios-sim", VPERIPH_VENDOR)
    end

    namespace :device do
      desc "Cross-build libmruby.a (iphoneos arm64, base reduced VM) and stage under examples/virtual-peripheral/Vendor"
      task lib: :setup do
        stage_libmruby("r2p2-picoruby-ios-device.rb", "ios-device", VPERIPH_VENDOR)
      end

      desc "Build the Virtual Peripheral app, signed, for the connected iOS device"
      task :build do
        dest = `xcodebuild -project #{VPERIPH_PROJ.shellescape} -scheme VirtualPeripheral -showdestinations 2>/dev/null`.lines
               .grep(/platform:iOS,/).reject { |l| l =~ /Simulator|placeholder/ }
               .first&.match(/id:(\S+)/)&.captures&.first
        raise "no connected iOS device destination (xcodebuild -showdestinations)" unless dest
        sh "xcodebuild -project #{VPERIPH_PROJ.shellescape} -scheme VirtualPeripheral " \
           "-destination 'id=#{dest}' " \
           "-derivedDataPath #{VPERIPH_DEVICE_DERIVED.shellescape} " \
           "ARCHS=arm64 -allowProvisioningUpdates build"
      end

      desc "Install and launch the Virtual Peripheral app on the connected iOS device"
      task :run do
        app = Dir.glob(File.join(VPERIPH_DEVICE_DERIVED, "Build", "Products",
                                 "*-iphoneos", "VirtualPeripheral.app")).first
        raise "app not built; run `rake ios:vperiph:device:build`" unless app
        dev = `xcrun devicectl list devices`.lines
              .grep(/iPhone|iPad/).first&.match(/([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})/)&.captures&.first
        raise "no connected iOS device (xcrun devicectl list devices)" unless dev
        sh "xcrun devicectl device install app --device #{dev} #{app.shellescape}"
        sh "xcrun devicectl device process launch --console --device #{dev} #{VPERIPH_BUNDLE}"
      end

      desc "Full Virtual Peripheral device pipeline: lib -> gen -> build -> run (needs a connected, signed device)"
      task all: [:lib, "ios:vperiph:gen", :build, :run]
    end

    desc "Generate the Virtual Peripheral Xcode project from project.yml"
    task :gen do
      sh "cd #{VPERIPH_DIR.shellescape} && xcodegen generate"
    end

    desc "Build the Virtual Peripheral app for the iOS Simulator"
    task :build do
      sh "xcodebuild -project #{VPERIPH_PROJ.shellescape} " \
         "-scheme VirtualPeripheral -destination 'generic/platform=iOS Simulator' " \
         "-derivedDataPath #{VPERIPH_DERIVED.shellescape} " \
         "ARCHS=arm64 ONLY_ACTIVE_ARCH=NO EXCLUDED_ARCHS=x86_64 build"
    end

    desc "Boot a simulator, install, and launch the Virtual Peripheral app"
    task :run do
      app = Dir.glob(File.join(VPERIPH_DERIVED, "Build", "Products",
                               "*-iphonesimulator", "VirtualPeripheral.app")).first
      raise "app not built; run `rake ios:vperiph:build`" unless app
      udid = `xcrun simctl list devices available`.lines
             .grep(/iPhone/).first&.match(/\(([0-9A-F-]{36})\)/)&.captures&.first
      raise "no available iPhone simulator" unless udid
      sh "xcrun simctl boot #{udid} 2>/dev/null; true"
      sh "open -a Simulator"
      sh "xcrun simctl install #{udid} #{app.shellescape}"
      sh "xcrun simctl launch #{udid} #{VPERIPH_BUNDLE}"
    end

    desc "Full Virtual Peripheral Simulator pipeline: lib -> gen -> build -> run"
    task all: [:lib, :gen, :build, :run]
  end
```

- [ ] **Step 3: Build + launch on the Simulator**

Run: `rake ios:vperiph:all`
Expected: `xcodegen` generates `VirtualPeripheral.xcodeproj`; `xcodebuild` ends `** BUILD SUCCEEDED **`; the app installs and launches on a booted iPhone simulator.

- [ ] **Step 4: Confirm the VM boots and the pipeline is wired**

Run (capture the app's unified-log output for ~6s):
```bash
udid=$(xcrun simctl list devices booted | grep -oE '\(([0-9A-F-]{36})\)' | tr -d '()' | head -1)
xcrun simctl spawn "$udid" log stream --style compact --predicate 'process == "VirtualPeripheral"' >/tmp/vperiph.log 2>&1 & p=$!
sleep 6; kill $p 2>/dev/null
grep -E "VM opened|BLE " /tmp/vperiph.log
```
Expected: a line `[VirtualPeripheral] VM opened`, and a BLE state line — on the Simulator this is `BLE unsupported here (the Simulator has no Bluetooth radio)` (the Simulator has no radio; this confirms the delegate path is wired). The real advertising/connect path is exercised only on a physical device (next, hardware-gated step — not part of this plan).

- [ ] **Step 5: Commit**

```bash
git add Rakefile examples/virtual-peripheral/project.yml
git commit -m "feat(vperiph): project.yml + ios:vperiph rake tasks; Simulator build/launch verified"
```

Note: `examples/virtual-peripheral/VirtualPeripheral.xcodeproj/` and `Vendor/` are generated/staged and are covered by the existing `.gitignore` patterns (`examples/*/*.xcodeproj`, `examples/*/Vendor/`); they are not committed.

---

## Hardware-gated next step (NOT executed by this plan)

On the physical iPhone (a one-time on-device Trust is needed for the new bundle id `com.bash0c7.picoruby.VirtualPeripheral`, per the REPL/stackchan flow):

1. `rake ios:vperiph:device:all` — build/sign/install/launch on the connected device.
2. The app advertises `PBLE-TEST` (Heart Rate profile by default). Verify connect + activity:
   - With **LightBlue** (Mac/iOS central): connect, read Body Sensor Location (→ Wrist), subscribe to Heart Rate Measurement (→ a bpm value once per second appears in the log).
   - For the **PC stackchan** path: set `ACTIVE_PROFILE = NUS_PROFILE` in `app.rb`, rebuild, and point the PC client at it (`BLE_NAME_PREFIX=PBLE-TEST`); confirm each written frame appears in the log and the client receives the `.` ACK / `<read:pos>` detail frame.

## Self-review notes

- **Spec coverage:** PicoRuby-first brain (Task 1), reduced-VM proof (Task 2), Swift radio + bridge (Tasks 3–4), read-only scrolling log + keyboard-safety (Task 5), base build-config reuse + no picoruby-ble + rake/project wiring + Simulator verification (Task 6), data-driven Heart-Rate-default/NUS-switchable profiles (Task 1 `ACTIVE_PROFILE`), hex bridge seam (Tasks 1 & 4). All spec sections map to a task.
- **Type/name consistency:** `vm_open`/`vm_call`/`callSync`, the `profile`/`on_read`/`on_write`/`on_subscribe`/`on_unsubscribe`/`tick` method set, the `<value>|<log>` and `<uuid>:<hex>` seam formats, and the canonical-lowercase-UUID keying are used identically across `app.rb`, the probe, and `PeripheralManager.swift`.
- **YAGNI:** no runtime profile switch, no manual frame injection, no connect/disconnect callbacks (CBPeripheralManager has none for the peripheral role), no bundled image/icon.
