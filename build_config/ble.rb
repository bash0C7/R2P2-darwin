# BLE host (POSIX) build for R2P2-macOS: standard picoruby + picoruby-ble with
# the Apple/Darwin (CoreBluetooth) port.
# Don't invoke directly — use `rake build:ble`.
#
# PICORB_PLATFORM_DARWIN (set in common.rb) makes build.darwin? true, which is
# how picoruby-ble's mrbgem.rake selects its ports/darwin sources, builds the
# CoreBluetooth Swift backend (PicoBLEDarwin) and links the resulting dylib.
load File.expand_path("common.rb", __dir__)

MRuby::Build.new do |conf|
  conf.toolchain :gcc

  R2P2MacOSBuild.base_defines(conf)

  conf.picoruby

  # networking gembox (and picoruby-mbedtls, a picoruby-ble dependency) link ssl/crypto.
  conf.linker.libraries << "ssl"
  conf.linker.libraries << "crypto"

  conf.gembox "mruby-posix"
  conf.gembox "minimum"
  conf.gembox "core"
  conf.gembox "stdlib"
  conf.gembox "shell"
  conf.gembox "networking"
  conf.gem core: "picoruby-shinonome"
  conf.gem core: "picoruby-bin-r2p2"
  conf.gem core: "picoruby-bin-picoruby"
  conf.gem core: "picoruby-ble"          # builds the Darwin/CoreBluetooth port
end
