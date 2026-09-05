# Phase 3 — picoruby-ble for iOS: findings (scratch, gitignored)

Port repo: `/Users/bash/dev/src/github.com/bash0C7/picoruby-ble-darwin-port`
- Its `.git` is a **worktree** of `/Users/bash/dev/src/github.com/bash0C7/picoruby/.git`.
- `origin = https://github.com/bash0C7/picoruby` (bash0C7 fork), `upstream = picoruby/picoruby.git`.
- Branch: `picoruby-ble-darwin-port`.
- DECISION: this is a fork OF picoruby/picoruby. Per repo policy ("vendored submodule / upstream fork (picoruby/picoruby) には絶対 commit しない"), I do NOT commit to it. Package.swift change left UNCOMMITTED in that repo and reported.

vendor/picoruby (the thing R2P2-iOS actually builds, `rake setup`): clone of **upstream picoruby/master** (HEAD 729ca155). It ALREADY contains picoruby-ble, picoruby-mbedtls, picoruby-rng, picoruby-cyw43, picoruby-base64 — but upstream picoruby-ble has only `ports/rp2040` (NO darwin port) and unconditionally `add_dependency 'picoruby-cyw43'` + `'picoruby-mbedtls'` with no posix/darwin gating. The Darwin port lives ONLY in the bash0C7 fork worktree.

## Central Ruby API (port repo paths)

- No separate `Central` class. `BLE.new(:central[, profile_data])`. `mrblib/ble.rb:82` `def initialize(role, profile_data=nil)`; `ble.rb:92` `init_central if @role == :central`. Subclass BLE and override `advertising_report_callback(adv_report)` (`ble_central.rb:79`,`:99`) and/or `packet_callback`.
- `scan`: `ble_central.rb:51` `def scan(scan_type: :passive, scan_interval: 0x60, scan_window: 0x30, timeout_ms: nil, stop_state: :TC_IDLE, debug: false)`. Calls `set_scan_params` (no-op on darwin) then `start(timeout_ms, stop_state)`.
- Device name from report: `AdvertisingReport` (`ble_advertising_report.rb`). `report.reports[:complete_local_name]` (AD 0x09) / `[:shortened_local_name]` (0x08). Convenience `name_include?(name)` (`ble_advertising_report.rb:58-60`). Darwin backend emits only complete_local_name from `CBAdvertisementDataLocalNameKey`.
- `connect`: `ble_central.rb:65` `def connect(adv_report)` → `gap_connect(adv_report.address, adv_report.address_type_code)`; on 0 sets `@state=:TC_W4_CONNECT`, `start(10, :TC_IDLE)`, returns true.
- @services: Array of Hash `{start_handle:,end_handle:,uuid128:,uuid32:,characteristics:[]}` (`ble_central.rb:126`). Characteristic Hash `{start_handle:,value_handle:,end_handle:,properties:,uuid128:,uuid32:,value:nil,descriptors:[]}` (`:156`). `attr_reader :services,:state` (`:43`).
- `write_value_of_characteristic_without_response`: NOT Ruby — C method, 3 req args, registered `src/mruby/ble_central.c:149`, argspec `"iiS"` (`ble_central.c:60`). Ruby call: `write_value_of_characteristic_without_response(conn_handle, value_handle, data_string)`. NOTE value_handle truncated to uint8 in darwin port.
- Resolve value_handle from UUID: no helper; walk `@services[..][:characteristics]`, match `chara[:uuid32]` or `chara[:uuid128]`, read `chara[:value_handle]`.
- Notifications/ACKs: event consts `ble_central.rb:3-19` (`NOTIFICATION=0xA7`, `GATT_EVENT_QUERY_COMPLETE=0xA0`, etc.). Canonical `packet_callback` treats 0xA7 as a TODO no-op (`ble_central.rb:297-300`); to consume notifications override packet_callback. Darwin notification packet layout `[0xA7,01,00,00, value_handle,00, len,00, value...]` (`PicoBLEPackets.swift:66-69`). No separate write-ACK.
- `start(timeout_ms=nil, stop_state=:no_stop)` (`ble.rb:125`): hci_power_on; loop {break on timeout/stop_state; `packet=pop_packet; packet_callback(packet) if packet`; heartbeat; sleep_ms 100}. `ensure` hci_power_off. On darwin `pop_packet` (`src/mruby/ble.c:83-105`, guarded by PICORB_PLATFORM_DARWIN) drains ONE packet from the Swift FIFO via `pble_drain_one` per tick.

## mrbgem.rake (port) — the integration crux

`mrbgems/picoruby-ble/mrbgem.rake`:
- `add_dependency 'picoruby-mbedtls'` (always); `add_dependency 'picoruby-cyw43' unless build.posix? || build.name =~ /esp32|xtensa-esp/`.
- `if build.darwin?` block (lines 11-35): sets `spec.cc.defines << 'PICORB_PLATFORM_DARWIN'`; runs `system("swift","build","-c","release",...)` to build the `PicoBLEDarwin` dylib + emit `PicoBLEDarwin-Swift.h`; adds `-LPicoBLEDarwin`, `-lPicoBLEDarwin`, rpath to the LINKER; compiles `ports/darwin/*.c` into spec.objs.
- `build.darwin?` (lib/picoruby/build.rb:137) == `cc.defines.include?("PICORB_PLATFORM_DARWIN")`. **The iOS cross configs DEFINE PICORB_PLATFORM_DARWIN → build.darwin? is TRUE → the swift build + dylib link fires during the iOS cross-build.** This is the problem: a macOS dylib must not be built/linked into the iOS libmruby.a.

## Dependency closure & iOS breakage risk

- picoruby-ble → picoruby-mbedtls (+ rng,base64), picoruby-cyw43 (added on iOS since not posix).
- picoruby-mbedtls (`mrbgem.rake`): git-clones mbedtls v3.6.2 to lib/mbedtls and compiles ALL of `library/*.c` (unless esp32). Pure crypto C — cross-compiles for iOS, but heavy + needs network to clone.
- picoruby-rng: `rng_random_byte_impl()` provided ONLY by `ports/posix/rng.c` (fopen /dev/urandom) or `ports/esp32`. The posix port compiles ONLY when `build.posix?` (lib/picoruby/build.rb:189 `setup_compilers` glob of `ports/posix`+`ports/common`). **iOS is DARWIN not POSIX → no rng backend compiled → `rng_random_byte_impl` is UNRESOLVED in libmruby.a, referenced by src/mruby/rng.c.** This breaks the eventual app link (a .a tolerates it; the app link won't unless provided). KEY iOS FINDING.
- picoruby-cyw43: pure Ruby spec; src/cyw43.c (+ports/rp2040 only). On iOS cyw43.c compiles but any rp2040-only backend symbols would be unresolved. ble.rb calls `CYW43.init` only `if @role == :something`? — actually `ble.rb` calls CYW43.init conditionally; needs runtime check (not a link issue if cyw43.c self-contained).

## ports/darwin C ↔ Swift
`ports/darwin/ble.c` `#include "PicoBLEDarwin-Swift.h"` and calls `pble_*`. The C COMPILE requires that header to exist. The `pble_*` SYMBOLS resolve from the Swift backend at app-link time (a static .a leaves them undefined — OK for archiving). Swift `@c public func` exports (PicoBLEExports.swift): pble_central_init, pble_power_on/off, pble_start_scan, pble_stop_scan, pble_connect, pble_discover_services/characteristics/descriptors, pble_read_value, pble_write_value, pble_write_descriptor, pble_drain_one. Backend product `PicoBLEDarwin` (dynamic lib, platforms `.macOS(.v11)`), singleton `PBLECentral.shared`.

## VERIFICATION RESULTS (this session)

### darwin? predicate gap (FIXED in build_config)
`vendor/picoruby` (upstream master) defines `posix?`/`wasm?` but NOT `darwin?`. The fork's mrbgem.rake calls `build.darwin?`. First `rake ios:lib` aborted: `NoMethodError: undefined method 'darwin?'`. Fixed by reopening `MRuby::Build` in each build_config to add `darwin?` (== PICORB_PLATFORM_DARWIN defined) guarded by `unless method_defined?`.

### rake ios:lib — PASS
Produces `build/ios-sim/lib/libmruby.a` (arm64, ~1.8MB). Included gems: mruby-compiler2, mruby-task, picoruby-base64, picoruby-ble, picoruby-cyw43, picoruby-mbedtls, picoruby-mruby, picoruby-rng. `.a` contains ble.o, ble_central.o, ble_peripheral.o (from src/ AND ports/darwin/). The Swift `swift build -c release` for PicoBLEDarwin DOES run (builds macOS arm64 dylib + emits PicoBLEDarwin-Swift.h, ~0.2s cached) — the dylib is a side artifact NOT linked into the .a (archiving ignores linker libs). mbedtls v3.6.2 git-cloned + whole library/*.c compiled for iphonesimulator/arm64.

### rake ios:device:lib — PASS
Produces `build/ios-device/lib/libmruby.a` (arm64 iphoneos, ~1.8MB), same gem set + BLE objects.

### Undefined symbols in BOTH iOS .a (and host .a) — the real integration finding
A static archive tolerates these; they must resolve at final link:
- 13× `_pble_*` — Swift CoreBluetooth backend (resolves in the iOS APP target / a host dylib). EXPECTED & intended.
- N× `_MbedTLS_*` / `_Mbedtls_*` — mbedtls glue defined in `picoruby-mbedtls/ports/common/{cipher,cmac,digest,hmac,md,pkey}.c`. These compile ONLY via upstream's `setup_compilers` hook (lib/picoruby/gem.rb:9) which fires `["posix","common"]` globs `return unless cc.build.posix?`. Our reduced config is NOT posix → ports/common not compiled → glue undefined. NOT a swift issue.
- 3× `_CYW43_*` — cyw43 has only `ports/rp2040`; no host/iOS backend. cyw43 is pulled in BECAUSE `add_dependency 'picoruby-cyw43' unless build.posix?` — non-posix build keeps the dep. Ruby guards `CYW43.init` with `if Object.const_defined?(:CYW43)` but the gem's src/cyw43.c still references `CYW43_*`.
- 1× `_rng_random_byte_impl` — defined only in `picoruby-rng/ports/posix/rng.c` (fopen /dev/urandom; benign on iOS) — posix-gated, not compiled.

ROOT CAUSE: the BLE gem's dependency closure was authored assuming `build.posix?` is true (which both enables ports/common+ports/posix compilation for mbedtls/rng AND drops the cyw43 dep). The iOS reduced config deliberately omits POSIX (originally to avoid picoruby-machine's macOS-unavailable gethostuuid). picoruby-machine is NOT in our gem set, so PICORB_PLATFORM_POSIX could in principle be re-enabled for these gems, but that is a larger ABI decision beyond producing the .a.

### rake smoke (host) — FAILS to link (recorded, expected)
`ld: symbol(s) not found for architecture arm64` — the smoke clang line links only libmruby.a (no Swift dylib, no mbedtls common ports, no frameworks). Undefined: all `_pble_*`, all `_MbedTLS_*`/`_Mbedtls_*`, `_CYW43_*`. This is the same gap as above surfaced at an actual link. To make smoke link you'd need: compile mbedtls ports/common + rng ports/posix, drop/stub cyw43, build+link the PicoBLEDarwin dylib, and link CoreBluetooth+Security+Foundation frameworks. That is app-integration territory; the .a deliverable does not require it.

## Package.swift
`ports/darwin/ext/Package.swift:9` `platforms: [.macOS(.v11)]`. Changed to `[.macOS(.v11), .iOS(.v13)]` for an iOS Swift build of the backend (which happens in the APP target, not here). Verified `swift build -c release --product PicoBLEDarwin` still succeeds for macOS after the change. LEFT UNCOMMITTED: the port repo is a git worktree of bash0C7/picoruby whose origin is the bash0C7 fork but which is a fork OF picoruby/picoruby (upstream remote present). Per repo policy (never commit to upstream forks of picoruby), the Package.swift edit stays uncommitted/staged in that repo and is reported.

## COMMITS (R2P2-iOS, branch feat/picoruby-ios-stackchan)
- 9c7f628 feat(ios): integrate picoruby-ble Darwin port into cross-build + host gem set (build_config x3 only). project.yml (pre-existing signing change by another track) and HANDOFF.md left untouched.

## NOT done / REMAINING (needs app target or device)
- Resolving pble_* / mbedtls-common / cyw43 / rng at link: belongs to the Phase 4 iOS app target (link the iOS PicoBLEDarwin Swift backend + CoreBluetooth/Security/Foundation frameworks; provide rng + mbedtls-common ports). Cannot be verified here without an app/device link.
- rake smoke (host) link: left failing-by-design (documented). To green it without an app you'd compile mbedtls ports/common + rng ports/posix, drop/stub cyw43, build+link the host PicoBLEDarwin dylib, link frameworks — declined as out of scope (Phase 4 / forcing).
- Enabling PICORB_PLATFORM_POSIX on iOS WOULD resolve mbedtls/cyw43/rng but PULLS IN mruby-io (a POSIX/IO gem) — violates the explicit "no POSIX gems on iOS" constraint, so rejected. Verified empirically.
</content>
