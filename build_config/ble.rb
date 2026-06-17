# BLE host (POSIX) build for R2P2-macOS: standard picoruby + picoruby-ble with
# the Apple/Darwin (CoreBluetooth) port under development.
# Don't invoke directly — use `rake build:ble`.
#
# STEP 1: links the Darwin port as C stubs (no CoreBluetooth yet), so this build
# does NOT link the rb-corebluetooth-mac Swift dylib. That linkage is added in a
# later step together with the real CoreBluetooth implementation.
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
  conf.gem core: "picoruby-ble"          # under development: Darwin/CoreBluetooth port
end
