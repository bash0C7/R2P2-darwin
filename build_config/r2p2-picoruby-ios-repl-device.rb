# iOS device (arm64, iphoneos SDK) full-REPL cross-build for picoruby →
# libmruby.a (physical device). prism compiler + VM are baked in, so Ruby is
# compiled & run at runtime in-app. Mirrors the cross-build shape of picoruby's
# r2p2-picoruby-pico2.rb (target cc + host_command) and R2P2-macOS darwin defines.
#
# Device counterpart of r2p2-picoruby-ios-repl-sim.rb; see that file for the
# iOS-IS-POSIX rationale, the darwin port-chain (conf.ports :darwin, :posix),
# and the gembox exclusions (minimum host binaries, networking/OpenSSL).

sdk_path = `xcrun --sdk iphoneos --show-sdk-path`.strip
clang    = `xcrun --sdk iphoneos --find clang`.strip
ar       = `xcrun --sdk iphoneos --find ar`.strip
ios_min  = ENV["IOS_MIN"] || "17.0"

MRuby::CrossBuild.new("ios-repl-device") do |conf|
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
  conf.cc.defines << "PICORB_PLATFORM_POSIX"   # iOS IS POSIX
  conf.cc.defines << "PICORB_PLATFORM_DARWIN"  # ...and darwin (additive)
  conf.cc.defines << "MRB_INT64"
  conf.cc.defines << "MRB_NO_BOXING"
  conf.cc.defines << "MRB_UTF8_STRING"

  # iOS port selection: darwin first, posix fallback.
  conf.ports :darwin, :posix

  conf.picoruby

  # minimum.gembox replacement without its host-only binaries (mruby-bin-mrbc /
  # picoruby-bin-picoruby): a cross-build can't produce host-runnable binaries.
  # The host mrbc tool is built by picoruby's build_mrbc_exec hook.
  conf.gem core: "mruby-compiler"

  conf.gembox "mruby-posix"
  conf.gembox "core"
  conf.gembox "stdlib"
  conf.gembox "shell"

  # rng/mbedtls darwin ports use SecRandomCopyBytes.
  conf.linker.flags << "-framework" << "Security"
end
