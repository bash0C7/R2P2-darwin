# iOS device (arm64, iphoneos SDK) cross-build for the Networking example: the
# full-REPL posix?=true VM PLUS picoruby-net-http on picoruby-socket.
#
# Device counterpart of r2p2-picoruby-ios-net-sim.rb; see that file for the full
# rationale: iOS-IS-POSIX, the darwin port-chain (conf.ports :darwin, :posix) that
# selects picoruby-socket's darwin port (BSD sockets + mbedTLS, no OpenSSL) and
# gives mbedtls/rng their SecRandomCopyBytes entropy ports.

sdk_path = `xcrun --sdk iphoneos --show-sdk-path`.strip
clang    = `xcrun --sdk iphoneos --find clang`.strip
ar       = `xcrun --sdk iphoneos --find ar`.strip
ios_min  = ENV["IOS_MIN"] || "17.0"

MRuby::CrossBuild.new("ios-net-device") do |conf|
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
  conf.cc.defines << "PICORB_PLATFORM_POSIX"   # iOS IS POSIX
  conf.cc.defines << "PICORB_PLATFORM_DARWIN"  # ...and darwin (additive)
  conf.cc.defines << "MRB_INT64"
  conf.cc.defines << "MRB_NO_BOXING"
  conf.cc.defines << "MRB_UTF8_STRING"

  # iOS port selection: darwin first, posix fallback.
  conf.ports :darwin, :posix

  conf.picoruby

  conf.gem core: "mruby-compiler"
  conf.gembox "mruby-posix"
  conf.gembox "core"
  conf.gembox "stdlib"
  conf.gembox "shell"

  # picoruby-net-http -> picoruby-socket (darwin port: mbedTLS) + picoruby-uri.
  # See the sim config for the full explanation.
  conf.gem core: "picoruby-net-http"

  # rng/mbedtls darwin ports use SecRandomCopyBytes.
  conf.linker.flags << "-framework" << "Security"
end
