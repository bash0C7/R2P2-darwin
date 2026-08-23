# watchOS device (arm64_32) cross-build for picoruby → libmruby.a for the
# watchos SDK (physical Apple Watch). Device counterpart of
# r2p2-picoruby-watchos-sim.rb: physical watchos SDK, arm64_32, the device
# version-min flag.
#
# task_hal_ios.c (shared bridge) is safe here despite its name: it uses only
# standard POSIX/Darwin APIs (clock_gettime, usleep) available on watchOS —
# it is the Darwin task HAL for every Apple platform in this repo.

sdk_path    = `xcrun --sdk watchos --show-sdk-path`.strip
clang       = `xcrun --sdk watchos --find clang`.strip
ar          = `xcrun --sdk watchos --find ar`.strip
watchos_min = ENV["WATCHOS_MIN"] || "11.0"

MRuby::CrossBuild.new("watchos-device") do |conf|
  conf.toolchain :clang

  # The gcc/clang toolchain adds -lm by default, but libm is part of libSystem
  # on Apple platforms and the SDK marks it unavailable as a separate library.
  # Remove it to avoid link failure.
  conf.linker.libraries.delete("m")

  conf.cc.command       = clang
  conf.linker.command   = clang
  conf.archiver.command = ar
  conf.cc.host_command  = "clang"   # builds mrbc / compiler for the host

  conf.cc.flags << "-arch" << "arm64_32"
  conf.cc.flags << "-isysroot" << sdk_path
  conf.cc.flags << "-mwatchos-version-min=#{watchos_min}"

  conf.cc.defines << "MRB_TICK_UNIT=4"
  conf.cc.defines << "MRB_TIMESLICE_TICK_COUNT=3"
  conf.cc.defines << "PICORB_ALLOC_ALIGN=8"
  conf.cc.defines << "PICORB_ALLOC_ESTALLOC"
  conf.cc.defines << "PICORB_PLATFORM_POSIX"   # Darwin IS POSIX (XNU + BSD libc)
  conf.cc.defines << "PICORB_PLATFORM_DARWIN"  # ...and darwin (additive)
  conf.cc.defines << "MRB_INT64"
  conf.cc.defines << "MRB_NO_BOXING"
  conf.cc.defines << "MRB_UTF8_STRING"

  conf.picoruby
  conf.gem core: "mruby-compiler"
  # darwin first for gems that ship a Darwin port, posix for the rest (same
  # chain as the iOS configs).
  conf.ports :darwin, :posix
  # picoruby-machine carries the Estalloc heap glue the VM links against
  # (mrb_basic_alloc_func / mrb_open_with_custom_alloc) and the Machine module.
  # Upstream configs get it through gembox "core"; this reduced gem set adds it
  # explicitly. The :darwin port is what gets compiled (first match).
  conf.gem core: "picoruby-machine"
end
