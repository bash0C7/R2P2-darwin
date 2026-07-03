# watchOS Simulator (arm64) cross-build for picoruby → libmruby.a for the
# watchsimulator SDK. Same darwin defines as the iOS sim config; only the SDK
# and version-min flag differ.
#
# task_hal_ios.c (shared bridge) is safe here despite its name: it uses only
# standard POSIX/Darwin APIs (clock_gettime, usleep) available on watchOS.
# The "ios" in the filename is historical; it is the Darwin task HAL for all
# Apple platforms in this repo.

sdk_path    = `xcrun --sdk watchsimulator --show-sdk-path`.strip
clang       = `xcrun --sdk watchsimulator --find clang`.strip
ar          = `xcrun --sdk watchsimulator --find ar`.strip
watchos_min = ENV["WATCHOS_MIN"] || "11.0"

MRuby::CrossBuild.new("watchos-sim") do |conf|
  conf.toolchain :clang

  # The gcc/clang toolchain sets -lm by default, but libm is part of
  # libSystem on Apple platforms and watchOS Simulator explicitly marks it
  # unavailable as a separate library. Remove it to avoid link failure.
  conf.linker.libraries.delete("m")

  conf.cc.command       = clang
  conf.linker.command   = clang
  conf.archiver.command = ar
  conf.cc.host_command  = "clang"   # builds mrbc / compiler for the host

  conf.cc.flags << "-arch" << "arm64"
  conf.cc.flags << "-isysroot" << sdk_path
  conf.cc.flags << "-mwatchos-simulator-version-min=#{watchos_min}"

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
end
