# iOS Simulator (arm64) cross-build for the Net (TLS) example: the bare picoruby
# VM/compiler (identical to r2p2-picoruby-ios-sim.rb) PLUS picoruby-net built over
# the host UNIX network stack. EXAMPLE-SCOPED — base sim config stays net-free.
#
# Route 1 (no Network.framework): picoruby-net's mrbgem.rake takes its POSIX/Darwin
# branch (UNIX sockets + mbedTLS, no LwIP/cyw43) because build.darwin? is true. iOS
# provides BSD sockets, so ports/posix/{dns,tcp_client,tls_client,udp_client,net}.c
# compile unchanged. TLS entropy comes from the mbedtls Darwin port
# (SecRandomCopyBytes), so conf.ports :darwin + -framework Security are required.
# Cleartext/non-ATS endpoints are gated by iOS ATS at runtime (route 2,
# Network.framework, is deferred until ATS forces it).

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
  conf.cc.defines << "PICORB_PLATFORM_DARWIN"
  conf.cc.defines << "MRB_INT64"
  conf.cc.defines << "MRB_NO_BOXING"
  conf.cc.defines << "MRB_UTF8_STRING"

  conf.picoruby

  conf.gem core: "mruby-compiler2"

  # --- Net (TLS): picoruby-net over UNIX sockets + mbedtls Darwin port -----------
  # net's mrbgem.rake darwin branch picks ports/posix/*.c (BSD sockets). conf.ports
  # :darwin makes its mbedtls/rng deps use their SecRandomCopyBytes ports;
  # -framework Security resolves SecRandomCopyBytes at app link.
  conf.ports :darwin
  conf.gem "#{MRUBY_ROOT}/mrbgems/picoruby-net"

  conf.linker.flags << "-framework" << "Security"
end
