# Host build used only to link the bridge smoke test (`rake smoke`). Its gem
# set is the shared core every iOS cross-build starts from (picoruby VM +
# mruby-compiler; each iOS config adds its own gems on top), so the smoke
# test, which links against THIS build, predicts what that shared core can
# run. Toolchain is host-appropriate (plain MRuby::Build, no -arch/-isysroot).
# Defines and port chain mirror the iOS configs (PICORB_PLATFORM_POSIX +
# PICORB_PLATFORM_DARWIN, conf.ports :darwin, :posix), so the host build
# compiles the same ports/darwin sources the cross-builds do: the smoke test
# exercises ports/darwin/machine.c on the host. Device-SDK-only breakage
# (APIs the iOS/watchOS SDKs forbid) is what `rake ios:<name>:device:check`
# and `rake watchos:led:device:check` catch.
MRuby::Build.new("host") do |conf|
  conf.toolchain :clang

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
