# Darwin host build for the StackChan PC-side daemon/CLI written in PicoRuby:
# the darwin-ble gem set (CoreBluetooth central; its networking gembox
# provides picoruby-drb/socket).
#
# Build:
#   MRUBY_CONFIG=$(pwd)/build_config/r2p2-stackchan-pc.rb rake setup macos:build
# Produces ./build/host/bin/{r2p2,picoruby}.

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
end
