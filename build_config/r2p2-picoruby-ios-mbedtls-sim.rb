# iOS Simulator (arm64) cross-build for the MbedTLS example: the bare picoruby
# VM/compiler (identical to r2p2-picoruby-ios-sim.rb) PLUS picoruby-mbedtls built
# with its Apple/Darwin port. EXAMPLE-SCOPED — the base sim config stays
# mbedtls-free so the REPL keeps linking standalone.
#
# picoruby-mbedtls depends on picoruby-rng + picoruby-base64; conf.gem resolves
# them. conf.ports :darwin makes both mbedtls (ports/darwin/timing_alt.c) and rng
# (ports/darwin/rng.c) compile their SecRandomCopyBytes-based ports instead of the
# /dev/urandom posix ports iOS sandboxes. Both need -framework Security at link.

sdk_path = `xcrun --sdk iphonesimulator --show-sdk-path`.strip
clang    = `xcrun --sdk iphonesimulator --find clang`.strip
ar       = `xcrun --sdk iphonesimulator --find ar`.strip
ios_min  = ENV["IOS_MIN"] || "17.0"

MRuby::CrossBuild.new("ios-mbedtls-sim") do |conf|
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

  # --- MbedTLS: picoruby-mbedtls + its Darwin port (+ rng/base64 deps) -----------
  # conf.ports :darwin selects ports/darwin for every gem that ships one:
  # mbedtls (timing_alt.c: clock_gettime timing + SecRandomCopyBytes hardware_poll)
  # and its rng dependency (rng.c: SecRandomCopyBytes). SecRandomCopyBytes resolves
  # via -framework Security at app link.
  conf.ports :darwin
  conf.gem "#{MRUBY_ROOT}/mrbgems/picoruby-mbedtls"

  conf.linker.flags << "-framework" << "Security"
end
