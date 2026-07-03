# iOS Simulator (arm64) cross-build for the RNG example: the bare picoruby
# VM/compiler (identical to r2p2-picoruby-ios-sim.rb) PLUS picoruby-rng built with
# its Apple/Darwin port (ports/darwin/rng.c -> SecRandomCopyBytes). EXAMPLE-SCOPED —
# the base sim config stays rng-free so the REPL keeps linking standalone.
#
# picoruby-rng's posix port open()s /dev/urandom, which iOS sandboxes. conf.ports
# :darwin makes effective_ports = [darwin], so gem.rb compiles ports/darwin/rng.c
# (SecRandomCopyBytes) instead. That needs -framework Security at link time. rng
# declares no add_dependency, so no mbedtls/cyw43-style dependency stripping.

sdk_path = `xcrun --sdk iphonesimulator --show-sdk-path`.strip
clang    = `xcrun --sdk iphonesimulator --find clang`.strip
ar       = `xcrun --sdk iphonesimulator --find ar`.strip
ios_min  = ENV["IOS_MIN"] || "17.0"

MRuby::CrossBuild.new("ios-rng-sim") do |conf|
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

  conf.gem core: "mruby-compiler"

  # --- RNG: picoruby-rng + its Darwin (SecRandomCopyBytes) port -------------------
  # conf.ports :darwin makes effective_ports include "darwin", so the gem compiles
  # ports/darwin/rng.c. SecRandomCopyBytes is resolved by -framework Security; the
  # symbol lives in libmruby.a and the framework links into the app target.
  conf.ports :darwin
  conf.gem "#{MRUBY_ROOT}/mrbgems/picoruby-rng"

  # rng.c calls SecRandomCopyBytes (Security.framework). The cross-build links
  # libmruby.a only, but the host mrbc/presym scan compiles no app binary, so the
  # framework flag only matters at app link — declared here for the app target.
  conf.linker.flags << "-framework" << "Security"
end
