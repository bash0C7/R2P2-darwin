# Darwin host build for the StackChan PC-side daemon/CLI written in PicoRuby.
# = the darwin-ble config (CoreBluetooth central) + picoruby-drb/socket (already
# via the networking gembox) + the shared StackChan layer gem
# (picoruby-stackchan-shared), which lives OUTSIDE the picoruby tree in the
# stackchan-picoruby repo and is pulled in by absolute gemdir.
#
# Build:
#   MRUBY_CONFIG=$(pwd)/build_config/r2p2-stackchan-pc.rb rake setup build
# Produces ./build/host/bin/{r2p2,picoruby} with the shared layer compiled in
# (Stackchan::BLE / Stackchan::AI available without `load`).

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
  conf.gembox "networking"          # picoruby-drb / picoruby-socket / picoruby-marshal
  conf.gem core: "picoruby-shinonome"
  conf.gem core: "picoruby-bin-picoruby"
  conf.gem core: "picoruby-bin-r2p2"
  conf.gem core: "picoruby-ble"
  conf.gem core: "picoruby-picotest"
  conf.gem gemdir: "/Users/bash/dev/src/github.com/bash0C7/stackchan-picoruby-pc-picoruby/mrbgems/picoruby-stackchan-shared"
end
