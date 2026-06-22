# iOS Simulator (arm64) cross-build for the iPhone Torch example: the bare picoruby
# VM/compiler (identical to r2p2-picoruby-ios-sim.rb) PLUS the local
# picoruby-iphone-torch gem built with its Darwin port. EXAMPLE-SCOPED — the base
# sim config stays torch-free so the REPL keeps linking standalone.
#
# The Darwin port (ports/darwin/torch.c) references only ptorch_* (provided by the
# PicoTorchDarwin Swift package at APP link time), so it pulls no extra gem deps.
# picoruby-ble-style mbedtls/cyw43 dependency stripping and the darwin? monkeypatch
# are NOT needed here: this gem declares no add_dependency and its mrbgem.rake never
# calls build.darwin?.

sdk_path = `xcrun --sdk iphonesimulator --show-sdk-path`.strip
clang    = `xcrun --sdk iphonesimulator --find clang`.strip
ar       = `xcrun --sdk iphonesimulator --find ar`.strip
ios_min  = ENV["IOS_MIN"] || "17.0"

MRuby::CrossBuild.new("ios-torch-sim") do |conf|
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

  # --- iPhone Torch: local picoruby-iphone-torch gem + its Darwin port -----------
  # conf.ports :darwin makes effective_ports include "darwin", so the gem compiles
  # ports/darwin/torch.c. ptorch_* stay undefined in libmruby.a (resolved when the
  # PicoTorchDarwin Swift package links into the app target).
  conf.ports :darwin
  conf.gem File.expand_path("../examples/iphone-torch/picoruby-iphone-torch", __dir__)
end
