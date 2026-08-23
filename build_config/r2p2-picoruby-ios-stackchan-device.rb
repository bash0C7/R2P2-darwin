# iOS device (iphoneos arm64) cross-build for the Stack-chan example: the bare
# picoruby VM/compiler PLUS picoruby-ble built with its Apple/Darwin
# (CoreBluetooth) port. EXAMPLE-SCOPED — BLE lives only in this config so
# every other target's libmruby.a keeps linking without it.
#
# Device counterpart of r2p2-picoruby-ios-stackchan-sim.rb; see that file for
# the full rationale on the darwin? fallback, the conf.ports :darwin port
# selection, and stripping the unused picoruby-mbedtls / picoruby-cyw43
# dependencies. Differs only in the iphoneos SDK and device version-min flag.

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

MRuby::CrossBuild.new("ios-stackchan-device") do |conf|
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
  conf.cc.flags << "-miphoneos-version-min=#{ios_min}"

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
  conf.ports :darwin, :posix
  # picoruby-machine carries the Estalloc heap glue the VM links against
  # (mrb_basic_alloc_func / mrb_open_with_custom_alloc) and the Machine module.
  # Upstream configs get it through gembox "core"; this reduced gem set adds it
  # explicitly. The :darwin port is what gets compiled (first match).
  conf.gem core: "picoruby-machine"

  ble_gemdir = ENV["PICORUBY_BLE_GEMDIR"] ||
    File.expand_path("../vendor/picoruby/mrbgems/picoruby-ble", __dir__)

  conf.cc.include_paths << "#{ble_gemdir}/ports/darwin/ext"

  # picoruby-ble's mrbgem.rake skips picoruby-cyw43 (rp2040 radio) when
  # build.darwin? is set. Its picoruby-mbedtls dependency stays: ble.rb does
  # `require 'mbedtls'` at boot and the GATT database hash uses MbedTLS::CMAC,
  # so stripping it leaves the BLE Ruby layer unloaded (BLE.new then fails with
  # "wrong number of arguments"). The mbedtls / rng darwin ports build for iOS
  # (SecRandomCopyBytes entropy; the app links -framework Security).
  conf.gem ble_gemdir
end
