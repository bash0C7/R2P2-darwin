# iOS Simulator (arm64) cross-build for the tilt-synth example: the bare
# picoruby VM/compiler (identical to r2p2-picoruby-ios-sim.rb) PLUS the local
# picoruby-iphone-motion and picoruby-iphone-synth gems, each built with its
# Darwin port. EXAMPLE-SCOPED -- the base sim config stays free of both so the
# REPL keeps linking standalone.
#
# Neither gem declares add_dependency or calls build.darwin?, so no
# picoruby-ble-style mbedtls/cyw43 stripping or darwin? monkeypatch is needed
# (same rationale as r2p2-picoruby-ios-torch-sim.rb).

sdk_path = `xcrun --sdk iphonesimulator --show-sdk-path`.strip
clang    = `xcrun --sdk iphonesimulator --find clang`.strip
ar       = `xcrun --sdk iphonesimulator --find ar`.strip
ios_min  = ENV["IOS_MIN"] || "17.0"

MRuby::CrossBuild.new("ios-tiltsynth-sim") do |conf|
  conf.toolchain :clang

  conf.linker.libraries.delete("m")

  conf.cc.command       = clang
  conf.linker.command   = clang
  conf.archiver.command = ar
  conf.cc.host_command  = "clang"

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

  # --- tilt-synth: local motion + synth gems, both with a Darwin port -----
  conf.ports :darwin
  conf.gem File.expand_path("../examples/ios/tilt-synth/picoruby-iphone-motion", __dir__)
  conf.gem File.expand_path("../examples/ios/tilt-synth/picoruby-iphone-synth", __dir__)
end
