# iOS Simulator (arm64) cross-build for the Stack-chan example: the bare
# picoruby VM/compiler PLUS picoruby-ble built with its Apple/Darwin
# (CoreBluetooth) port. EXAMPLE-SCOPED — BLE lives only in this config so
# every other target's libmruby.a keeps linking without it.
#
# picoruby-ble declares add_dependency on picoruby-mbedtls / picoruby-cyw43,
# which the Darwin BLE path never uses; the conf.gem block below strips them
# (full rationale there). The cc.defines below are the define set shared by
# every cross-build config in this repo; MRB_INT64 / MRB_NO_BOXING in
# particular fix the mrb_value ABI.

sdk_path = `xcrun --sdk iphonesimulator --show-sdk-path`.strip
clang    = `xcrun --sdk iphonesimulator --find clang`.strip
ar       = `xcrun --sdk iphonesimulator --find ar`.strip
ios_min  = ENV["IOS_MIN"] || "17.0"

# picoruby-ble's mrbgem.rake calls build.darwin?; on a picoruby tree whose
# build system lacks that predicate, loading the gem raises NoMethodError, so
# install a false fallback (guarded — a tree that defines darwin? keeps its
# own). false is the right answer for an iOS static-.a cross-build: the gem's
# `if build.darwin?` branch (swift build of a macOS dylib + -lPicoBLEDarwin
# linker flags + its own ports glob) is macOS-host glue. This config does the
# Darwin port selection itself (conf.ports :darwin) and adds the Swift-header
# include path — keeping the iOS glue in this repo, not the picoruby tree.
# The Swift backend links into the APP target, not into libmruby.a; pble_*
# stay undefined in the .a, which is expected.
module MRuby
  class Build
    def darwin?
      false
    end unless method_defined?(:darwin?)
  end
end

MRuby::CrossBuild.new("ios-stackchan-sim") do |conf|
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
  conf.cc.flags << "-mios-simulator-version-min=#{ios_min}"

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
  # three mruby gems in directly.
  mruby_mrbgems = "#{MRUBY_ROOT}/mrbgems/picoruby-mruby/lib/mruby/mrbgems"
  conf.gem gemdir: "#{mruby_mrbgems}/mruby-string-ext"
  conf.gem gemdir: "#{mruby_mrbgems}/mruby-pack"
  conf.gem gemdir: "#{mruby_mrbgems}/mruby-sprintf"

  # --- Stack-chan: picoruby-ble + CoreBluetooth Darwin port -----------------
  # Select the Darwin port for every gem that ships one. picoruby-ble's `setup`
  # then compiles ports/darwin/*.c (the BLE_* port ABI -> pble_* Swift backend)
  # in place of the default rp2040/posix port.
  conf.ports :darwin, :posix
  # picoruby-machine carries the Estalloc heap glue the VM links against
  # (mrb_basic_alloc_func / mrb_open_with_custom_alloc) and the Machine module.
  # Upstream configs get it through gembox "core"; this reduced gem set adds it
  # explicitly. The :darwin port is what gets compiled (first match).
  conf.gem core: "picoruby-machine"

  # Defaults to vendor/picoruby's picoruby-ble (the fork tree carries the
  # darwin port, its Package.swift, and the generated PicoBLEDarwin-Swift.h);
  # PICORUBY_BLE_GEMDIR points at an alternate worktree.
  ble_gemdir = ENV["PICORUBY_BLE_GEMDIR"] ||
    File.expand_path("../vendor/picoruby/mrbgems/picoruby-ble", __dir__)

  # ports/darwin/*.c do `#include "PicoBLEDarwin-Swift.h"`, which lives in the
  # port's Swift package ext dir, not next to the .c. Put it on the include path.
  conf.cc.include_paths << "#{ble_gemdir}/ports/darwin/ext"

  # picoruby-ble declares add_dependency 'picoruby-mbedtls' and 'picoruby-cyw43'
  # (rp2040-only radio). The Darwin C path references neither: src/*.c and
  # ports/darwin/*.c contain no CYW43_*/MbedTLS_* C symbols — their only mentions
  # are runtime Ruby `require`s. Dependency resolution would otherwise compile
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
