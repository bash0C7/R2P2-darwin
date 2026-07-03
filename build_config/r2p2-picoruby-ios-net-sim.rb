# iOS Simulator (arm64) cross-build for the Networking example: the full-REPL
# posix?=true VM (identical gembox set to r2p2-picoruby-ios-repl-sim.rb) PLUS the
# picoruby-net HTTP/TLS stack built against its POSIX port (UNIX sockets + mbedTLS).
# EXAMPLE-SCOPED — the base/REPL configs stay networking-free so they keep linking
# without the socket/TLS surface.
#
# iOS IS POSIX, so picoruby-net's `if build.posix?` branch compiles ports/posix/
# {dns,tcp_client,tls_client,udp_client,net}.c (standard UNIX network stack) and
# does NOT pull picoruby-cyw43 (rp2040-only radio). TLS entropy comes from the
# picoruby-mbedtls + picoruby-rng DARWIN ports (SecRandomCopyBytes), selected over
# their /dev/urandom posix siblings by `conf.ports :darwin, :posix` and resolved at
# app link via -framework Security.
#
# IMPORTANT — picoruby-net, NOT picoruby-net-http. PicoRuby ships two HTTP stacks:
#   * picoruby-net      -> Net::HTTPSClient, self-contained mbedTLS TLS via its own
#                          ports/posix/tls_client.c. No OpenSSL. iOS-friendly.
#   * picoruby-net-http -> Net::HTTP (CRuby-compatible) but depends on picoruby-socket,
#                          whose posix SSLSocket links OpenSSL (SSL_connect, ...). iOS
#                          ships no linkable OpenSSL, so that path leaves unresolved
#                          OpenSSL symbols. It is the WRONG gem for iOS.
# We add picoruby-net so TLS goes entirely through mbedTLS + the darwin entropy port.

sdk_path = `xcrun --sdk iphonesimulator --show-sdk-path`.strip
clang    = `xcrun --sdk iphonesimulator --find clang`.strip
ar       = `xcrun --sdk iphonesimulator --find ar`.strip
ios_min  = ENV["IOS_MIN"] || "17.0"

MRuby::CrossBuild.new("ios-net-sim") do |conf|
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

  # HTTP/TLS over the POSIX net stack. picoruby-net ->
  # picoruby-mbedtls / picoruby-time / picoruby-pack / picoruby-jwt (resolved by
  # conf.gem). cyw43 is skipped because build.posix? is true.
  #
  # picoruby-net declares add_dependency 'picoruby-pack', which add_conflicts
  # 'mruby-pack'. The full-REPL gemboxes (core/stdlib) already provide mruby-pack
  # (Array#pack / String#unpack) — the same surface picoruby-pack reimplements for
  # the picoruby VM, which is exactly why the two conflict. Strip net's
  # picoruby-pack declaration so dependency resolution uses the already-present
  # mruby-pack instead of failing on the conflict.
  net_gemdir = "#{MRUBY_ROOT}/mrbgems/picoruby-net"
  conf.gem net_gemdir do |spec|
    spec.dependencies.reject! { |d| d[:gem] == "picoruby-pack" }
  end

  # rng/mbedtls darwin ports use SecRandomCopyBytes.
  conf.linker.flags << "-framework" << "Security"
end
