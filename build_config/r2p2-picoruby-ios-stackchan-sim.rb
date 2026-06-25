# iOS Simulator (arm64) cross-build for the Stack-chan example: the bare picoruby
# VM/compiler (identical to r2p2-picoruby-ios-sim.rb) PLUS picoruby-ble built with
# its Apple/Darwin (CoreBluetooth) port. EXAMPLE-SCOPED — the base sim config stays
# BLE-free so the REPL keeps linking standalone.
#
# The Darwin BLE path uses NEITHER cyw43 (rp2040-only radio) NOR mbedtls at the C
# layer: ports/darwin/*.c + src/*.c reference no CYW43_*/MbedTLS_* C symbols (their
# only mentions are runtime Ruby `require`s). picoruby-ble's mrbgem.rake still
# DECLARES add_dependency on those gems, which would (a) force them to be compiled
# and (b) drag in their rp2040/posix ports that this build never produces. We strip
# those two dependency declarations from the loaded spec so dependency resolution
# neither pulls nor fails on them. See r2p2-picoruby-ios-sim.rb for the load-bearing
# ABI defines copied verbatim below.

sdk_path = `xcrun --sdk iphonesimulator --show-sdk-path`.strip
clang    = `xcrun --sdk iphonesimulator --find clang`.strip
ar       = `xcrun --sdk iphonesimulator --find ar`.strip
ios_min  = ENV["IOS_MIN"] || "17.0"

# vendor/picoruby (upstream master) defines build.posix?/wasm? but NOT darwin?.
# The bash0C7 fork's picoruby-ble mrbgem.rake references build.darwin?, so the
# predicate must exist or loading that gem raises NoMethodError. We define it to
# return false: the fork's `if build.darwin?` block (swift build of a macOS dylib +
# -lPicoBLEDarwin linker flags + its own ports glob) is the WRONG thing for an iOS
# static-.a cross-build. Instead this config does the Darwin port selection itself
# (conf.ports :darwin) and adds the Swift-header include path — keeping all iOS glue
# in R2P2-iOS, not the fork. The Swift backend links into the APP target (Phase 4),
# not into libmruby.a; pble_* stay undefined in the .a, which is expected.
module MRuby
  class Build
    def darwin?
      false
    end unless method_defined?(:darwin?)
  end
end

MRuby::CrossBuild.new("ios-stackchan-sim") do |conf|
  conf.toolchain :clang

  # The gcc/clang toolchain sets -lm by default, but libm is part of
  # libSystem on Apple platforms and iOS Simulator explicitly marks it
  # unavailable as a separate library. Remove it to avoid link failure.
  conf.linker.libraries.delete("m")

  conf.cc.command       = clang
  conf.linker.command   = clang
  conf.archiver.command = ar
  conf.cc.host_command  = "clang"   # builds mrbc / compiler for the host

  conf.cc.flags << "-arch" << "arm64"
  conf.cc.flags << "-isysroot" << sdk_path
  conf.cc.flags << "-mios-simulator-version-min=#{ios_min}"

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

  # picoruby-ble's mrblib uses Array#pack / String#<< / sprintf. These live in
  # PicoRuby's stdlib.gembox (vm_mruby branch) which the minimal base config omits.
  mruby_mrbgems = "#{MRUBY_ROOT}/mrbgems/picoruby-mruby/lib/mruby/mrbgems"
  conf.gem gemdir: "#{mruby_mrbgems}/mruby-string-ext"
  conf.gem gemdir: "#{mruby_mrbgems}/mruby-pack"
  conf.gem gemdir: "#{mruby_mrbgems}/mruby-sprintf"

  # --- Stack-chan: picoruby-ble + CoreBluetooth Darwin port -----------------
  # Select the Darwin port for every gem that ships one. picoruby-ble's `setup`
  # then compiles ports/darwin/*.c (the BLE_* port ABI -> pble_* Swift backend)
  # in place of the default rp2040/posix port.
  conf.ports :darwin

  # The gem lives in the bash0C7 picoruby fork worktree (its iOS-ready
  # Package.swift + generated PicoBLEDarwin-Swift.h), not in vendor/picoruby.
  ble_gemdir = ENV["PICORUBY_BLE_GEMDIR"] ||
    File.expand_path("../vendor/picoruby/mrbgems/picoruby-ble", __dir__)

  # ports/darwin/*.c do `#include "PicoBLEDarwin-Swift.h"`, which lives in the
  # port's Swift package ext dir, not next to the .c. Put it on the include path.
  conf.cc.include_paths << "#{ble_gemdir}/ports/darwin/ext"

  # picoruby-ble declares add_dependency 'picoruby-mbedtls' and 'picoruby-cyw43'.
  # The Darwin C path references neither (verified: no CYW43_*/MbedTLS_* C symbols
  # in src/*.c or ports/darwin/*.c). Dependency resolution would otherwise compile
  # both gems and their rp2040/posix ports (and their own transitive picoruby-rng /
  # picoruby-base64), which this build does not produce, yielding undefined
  # CYW43_*/MbedTLS_*/rng_* symbols the Darwin path never calls. The add_dependency
  # calls run inside the spec's `setup` (the gem's mrbgem.rake initializer); the
  # block passed to conf.gem runs LATER in the same setup, after @dependencies is
  # populated, so strip the two declarations there.
  conf.gem ble_gemdir do |spec|
    spec.dependencies.reject! { |d| %w[picoruby-mbedtls picoruby-cyw43].include?(d[:gem]) }
  end
end
