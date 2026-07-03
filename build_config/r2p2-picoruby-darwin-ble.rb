# Darwin host build for picoruby with the picoruby-ble CoreBluetooth port
# opted in. Used by the BLE Example in README.md.
#
# Requires a picoruby tree that carries mrbgems/picoruby-ble/ports/darwin/
# (e.g. https://github.com/bash0C7/picoruby.git branch picoruby-ble-darwin-port,
# as of 2026-06-20). picoruby-picotest is included so the port's tests can run.

MRuby::Build.new do |conf|
  conf.toolchain :gcc

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

  conf.linker.libraries << "ssl"
  conf.linker.libraries << "crypto"

  conf.gembox "mruby-posix"
  conf.gembox "minimum"
  conf.gembox "core"
  conf.gembox "stdlib"
  conf.gembox "shell"
  conf.gembox "networking"
  conf.gem core: "picoruby-shinonome"
  conf.gem core: "picoruby-bin-picoruby"
  conf.gem core: "picoruby-bin-r2p2"
  conf.gem core: "picoruby-ble"
  conf.gem core: "picoruby-picotest"
end
