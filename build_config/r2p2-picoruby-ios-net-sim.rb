# iOS Simulator (arm64) cross-build for the Networking example: the full-REPL
# posix?=true VM (identical gembox set to r2p2-picoruby-ios-repl-sim.rb) PLUS
# upstream picoruby's HTTP stack: picoruby-net-http (Net::HTTP) on
# picoruby-socket (BSD sockets + TLS). EXAMPLE-SCOPED — the REPL configs stay
# networking-free so they keep linking without the socket/TLS surface.
#
# TLS on iOS: picoruby-socket's posix port links OpenSSL, which iOS does not
# ship. With `conf.ports :darwin, :posix` the gem's ports/darwin (fork
# port-darwin) is compiled instead: the same BSD socket code plus an
# mbedTLS-backed SSLSocket, with entropy from the picoruby-mbedtls /
# picoruby-rng darwin ports (SecRandomCopyBytes, resolved at app link via
# -framework Security). macOS host builds set no conf.ports and keep the
# posix/OpenSSL port.

sdk_path = `xcrun --sdk iphonesimulator --show-sdk-path`.strip
clang    = `xcrun --sdk iphonesimulator --find clang`.strip
ar       = `xcrun --sdk iphonesimulator --find ar`.strip
ios_min  = ENV["IOS_MIN"] || "17.0"

MRuby::CrossBuild.new("ios-net-sim") do |conf|
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
  conf.cc.defines << "PICORB_PLATFORM_POSIX"   # iOS IS POSIX
  conf.cc.defines << "PICORB_PLATFORM_DARWIN"  # ...and darwin (additive)
  conf.cc.defines << "MRB_INT64"
  conf.cc.defines << "MRB_NO_BOXING"
  conf.cc.defines << "MRB_UTF8_STRING"

  # iOS port selection: darwin first, posix fallback. Gives mbedtls/rng their
  # SecRandomCopyBytes entropy ports; net itself has only a posix port (picked up
  # by its build.posix? branch, not by ports selection).
  conf.ports :darwin, :posix

  conf.picoruby

  # Full-REPL surface (minus host-only binaries), identical to the REPL config so
  # the networking example can also run interactive Ruby.
  conf.gem core: "mruby-compiler"
  conf.gembox "mruby-posix"
  conf.gembox "core"
  conf.gembox "stdlib"
  conf.gembox "shell"

  # HTTP over BSD sockets: upstream split picoruby-net into picoruby-net-http
  # (+ -ntp / -websocket / -mqtt) on top of picoruby-socket; net-http pulls in
  # picoruby-socket and picoruby-uri itself. The ports chain above makes
  # picoruby-socket compile its darwin port (mbedTLS SSLSocket, no OpenSSL).
  conf.gem core: "picoruby-net-http"

  # rng/mbedtls darwin ports use SecRandomCopyBytes.
  conf.linker.flags << "-framework" << "Security"
end
