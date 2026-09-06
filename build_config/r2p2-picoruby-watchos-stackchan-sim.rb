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
