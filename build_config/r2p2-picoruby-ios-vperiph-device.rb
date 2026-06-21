# iOS device (iphoneos arm64) cross-build for the Virtual Peripheral example: the bare
# picoruby VM/compiler (identical to r2p2-picoruby-ios-device.rb) PLUS picoruby-ble
# built with its Apple/Darwin (CoreBluetooth) port. EXAMPLE-SCOPED — the base device
# config stays BLE-free so the REPL keeps linking standalone.
#
# See r2p2-picoruby-ios-stackchan-sim.rb for the full rationale on the darwin?
# predicate, the conf.ports :darwin port selection, and stripping the unused
# picoruby-mbedtls / picoruby-cyw43 dependencies. This file differs from it ONLY in
# the iphoneos SDK / version-min flag (the device toolchain), copied verbatim from
# r2p2-picoruby-ios-device.rb.

sdk_path = `xcrun --sdk iphoneos --show-sdk-path`.strip
clang    = `xcrun --sdk iphoneos --find clang`.strip
ar       = `xcrun --sdk iphoneos --find ar`.strip
ios_min  = ENV["IOS_MIN"] || "17.0"

module MRuby
  class Build
    def darwin?
      false
    end unless method_defined?(:darwin?)
  end
end

MRuby::CrossBuild.new("ios-vperiph-device") do |conf|
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
  conf.cc.flags << "-miphoneos-version-min=#{ios_min}"

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

  # --- Virtual Peripheral: picoruby-ble + CoreBluetooth Darwin port -----------------
  conf.ports :darwin

  ble_gemdir = ENV["PICORUBY_BLE_GEMDIR"] ||
    File.expand_path("../../picoruby-ble-darwin-port/mrbgems/picoruby-ble", __dir__)

  conf.cc.include_paths << "#{ble_gemdir}/ports/darwin/ext"

  conf.gem ble_gemdir do |spec|
    spec.dependencies.reject! { |d| %w[picoruby-mbedtls picoruby-cyw43].include?(d[:gem]) }
  end
end
