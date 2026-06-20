# iOS Simulator (arm64) cross-build for picoruby → libmruby.a for the
# iphonesimulator SDK. prism compiler + VM are baked in, so Ruby is compiled &
# run at runtime in-app. Mirrors the cross-build shape of picoruby's
# r2p2-picoruby-pico2.rb (target cc + host_command) and R2P2-macOS darwin defines.
# Gemboxes minimal (core + stdlib + compiler) — POSIX/shell/networking dropped.

sdk_path = `xcrun --sdk iphonesimulator --show-sdk-path`.strip
clang    = `xcrun --sdk iphonesimulator --find clang`.strip
ar       = `xcrun --sdk iphonesimulator --find ar`.strip
ios_min  = ENV["IOS_MIN"] || "17.0"

MRuby::CrossBuild.new("ios-sim") do |conf|
  conf.toolchain :clang

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
  conf.cc.defines << "PICORB_PLATFORM_POSIX"
  conf.cc.defines << "PICORB_PLATFORM_DARWIN"
  conf.cc.defines << "MRB_INT64"
  conf.cc.defines << "MRB_NO_BOXING"
  conf.cc.defines << "MRB_UTF8_STRING"

  conf.picoruby

  conf.gem core: "mruby-compiler2"
  conf.gem core: "mruby-bin-mrbc2"
  conf.gem core: "picoruby-mruby"

  conf.gembox "core"
  conf.gembox "stdlib"
end
