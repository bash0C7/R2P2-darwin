# iOS Simulator (arm64) cross-build for the IO.console example: the bare picoruby
# VM/compiler (identical to r2p2-picoruby-ios-sim.rb) PLUS picoruby-io-console
# built with its Apple/Darwin port. EXAMPLE-SCOPED — the base sim config stays
# io-console-free so the REPL keeps linking standalone.
#
# The posix port drives stdin via termios. iOS has no controlling TTY, so the
# Darwin port (ports/darwin/io-console.c) splits on TargetConditionals: no-TTY
# stubs for iOS, termios reuse for macOS. conf.ports :darwin selects it. No extra
# frameworks or gem dependencies.

sdk_path = `xcrun --sdk iphonesimulator --show-sdk-path`.strip
clang    = `xcrun --sdk iphonesimulator --find clang`.strip
ar       = `xcrun --sdk iphonesimulator --find ar`.strip
ios_min  = ENV["IOS_MIN"] || "17.0"

MRuby::CrossBuild.new("ios-io-console-sim") do |conf|
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

  # --- IO.console: picoruby-io-console + its Darwin (no-TTY / termios) port -------
  # conf.ports :darwin makes effective_ports include "darwin", so the gem compiles
  # ports/darwin/io-console.c (iOS stubs under TARGET_OS_IPHONE).
  conf.ports :darwin
  conf.gem "#{MRUBY_ROOT}/mrbgems/picoruby-io-console"
end
