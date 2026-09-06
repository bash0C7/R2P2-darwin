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
