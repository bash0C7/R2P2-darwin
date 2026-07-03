require "shellwords"
require "rbconfig"

ROOT          = __dir__
PICORUBY_REPO = ENV["PICORUBY_REPO"] || "https://github.com/bash0C7/picoruby.git"
PICORUBY_REF  = ENV["PICORUBY_REF"]  || "port-darwin"
PICORUBY_SRC  = File.join(ROOT, "vendor", "picoruby")
BUILD_DIR     = File.join(ROOT, "build")
EXAMPLE       = ENV["EXAMPLE"] || "repl"
APP_DIR       = File.join(ROOT, "examples", EXAMPLE)
VENDOR_DIR    = File.join(APP_DIR, "Vendor")
BUNDLE_ID     = "com.bash0c7.picoruby.PicoRubyRunner"

def mruby_env(cfg)
  { "MRUBY_BUILD_DIR" => BUILD_DIR, "MRUBY_CONFIG" => File.absolute_path(cfg) }
end

# Cross-build libmruby.a with the given build_config and stage the archive +
# picoruby headers under <vendor_dir>. `build_name` is the MRuby build name (the
# build/<name>/ output dir). Shared by each example's lib task.
def stage_libmruby(config_basename, build_name, vendor_dir)
  cfg = File.join(ROOT, "build_config", config_basename)
  sh mruby_env(cfg), "cd #{PICORUBY_SRC.shellescape} && rake"
  lib = File.join(BUILD_DIR, build_name, "lib", "libmruby.a")
  raise "expected #{lib} not found" unless File.file?(lib)
  rm_rf vendor_dir
  mkdir_p File.join(vendor_dir, "lib")
  mkdir_p File.join(vendor_dir, "include")
  cp lib, File.join(vendor_dir, "lib", "libmruby.a")
  cp_r File.join(PICORUBY_SRC, "include", "."), File.join(vendor_dir, "include")
  puts "Staged #{build_name} libmruby.a + headers under #{vendor_dir}"
end

# picoruby vendors mruby, which vendors prism (mrbgems/mruby-compiler-prism).
# That prism checkout ships its templates but NOT the files they generate;
# include/prism/diagnostic.h in particular is produced by templates/template.rb.
# The host mrbc tool (built by picoruby's build_mrbc_exec hook) compiles this
# prism during the presym scan, which runs before any mrbgem.rake gets a chance
# to fire the generator — so on a clean clone the header is missing and the
# build aborts. Generate it here, right after fetch, so it always exists before
# the first build. Idempotent: the generator overwrites with identical content,
# and we skip entirely when the header is already present (e.g. a picoruby
# that generates it itself) or when the template layout has moved.
PRISM_TEMPLATE_DIR = File.join(
  PICORUBY_SRC,
  "mrbgems", "picoruby-mruby", "lib", "mruby",
  "mrbgems", "mruby-compiler-prism", "lib", "prism"
)

def generate_prism_templates
  template = File.join(PRISM_TEMPLATE_DIR, "templates", "template.rb")
  generated = File.join(PRISM_TEMPLATE_DIR, "include", "prism", "diagnostic.h")
  unless File.exist?(template)
    puts "prism templates: template.rb absent (#{template}); skipping"
    return
  end
  if File.exist?(generated)
    puts "prism templates: diagnostic.h already present; skipping"
    return
  end
  sh "cd #{PRISM_TEMPLATE_DIR.shellescape} && #{RbConfig.ruby.shellescape} templates/template.rb"
end

desc "Verify iOS build prerequisites"
task :check do
  if File.directory?("/Applications/Xcode.app") &&
     system("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path", out: File::NULL, err: File::NULL)
    puts "iOS SDK:    ok"
  else
    abort "iOS SDK:    missing — install full Xcode.app (App Store); CLT alone is not enough"
  end
  if system("which", "xcodegen", out: File::NULL, err: File::NULL)
    puts "xcodegen:   ok"
  else
    warn "xcodegen:   missing — run `brew install xcodegen`"
  end
end

desc "Fetch picoruby into vendor/picoruby"
task :setup do
  unless Dir.exist?(PICORUBY_SRC)
    sh "git clone --recursive --branch #{PICORUBY_REF.shellescape} " \
       "#{PICORUBY_REPO.shellescape} #{PICORUBY_SRC.shellescape}"
  end
  generate_prism_templates
end

desc "Re-fetch PICORUBY_REF into the existing vendor/picoruby"
task :refresh do
  raise "vendor/picoruby absent; run `rake setup`" unless Dir.exist?(PICORUBY_SRC)
  sh "git -C #{PICORUBY_SRC.shellescape} fetch #{PICORUBY_REPO.shellescape} #{PICORUBY_REF.shellescape}"
  sh "git -C #{PICORUBY_SRC.shellescape} checkout -B #{PICORUBY_REF.shellescape} FETCH_HEAD"
  sh "git -C #{PICORUBY_SRC.shellescape} submodule update --init --recursive"
  generate_prism_templates
end

namespace :ios do
  desc "Cross-build libmruby.a for the iOS Simulator and stage under app/Vendor"
  task lib: :setup do
    # Full REPL (posix?=true + darwin port-chain): the complete core/stdlib/shell
    # gembox set. BLE-free, so the REPL example stays self-contained.
    stage_libmruby("r2p2-picoruby-ios-repl-sim.rb", "ios-repl-sim", VENDOR_DIR)
  end

  namespace :device do
    desc "Cross-build libmruby.a for an iOS device (iphoneos arm64) and stage under app/Vendor"
    task lib: :setup do
      stage_libmruby("r2p2-picoruby-ios-repl-device.rb", "ios-repl-device", VENDOR_DIR)
    end

    desc "Build the app, signed, for the connected iOS device"
    task :build do
      proj = File.join(APP_DIR, "PicoRubyRunner.xcodeproj")
      # Target the SPECIFIC connected device (not generic/platform=iOS) so
      # -allowProvisioningUpdates can register it with the Personal Team and
      # generate a profile. Device slice is arm64; automatic signing resolves
      # the team set in the example's project.yml.
      dest = `xcodebuild -project #{proj.shellescape} -scheme PicoRubyRunner -showdestinations 2>/dev/null`.lines
             .grep(/platform:iOS,/).reject { |l| l =~ /Simulator|placeholder/ }
             .first&.match(/id:(\S+)/)&.captures&.first
      raise "no connected iOS device destination (xcodebuild -showdestinations)" unless dest
      sh "xcodebuild -project #{proj.shellescape} -scheme PicoRubyRunner " \
         "-destination 'id=#{dest}' " \
         "-derivedDataPath #{File.join(ROOT, "build", "ios-app-device").shellescape} " \
         "ARCHS=arm64 -allowProvisioningUpdates build"
    end

    desc "Install and launch the app on the connected iOS device"
    task :run do
      derived = File.join(ROOT, "build", "ios-app-device")
      app = Dir.glob(File.join(derived, "Build", "Products", "*-iphoneos", "PicoRubyRunner.app")).first
      raise "app not built; run `rake ios:device:build`" unless app
      dev = `xcrun devicectl list devices`.lines
            .grep(/iPhone|iPad/).first&.match(/([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})/)&.captures&.first
      raise "no connected iOS device (xcrun devicectl list devices)" unless dev
      sh "xcrun devicectl device install app --device #{dev} #{app.shellescape}"
      sh "xcrun devicectl device process launch --console --device #{dev} #{BUNDLE_ID}"
    end

    desc "Full device pipeline: lib -> gen -> build -> run (needs a connected, signed device)"
    task all: [:lib, "ios:gen", :build, :run]
  end

  namespace :stackchan do
    STACKCHAN_DIR     = File.join(ROOT, "examples", "stackchan")
    STACKCHAN_PROJ    = File.join(STACKCHAN_DIR, "Stackchan.xcodeproj")
    STACKCHAN_BUNDLE  = "com.bash0c7.picoruby.Stackchan"
    STACKCHAN_VENDOR  = File.join(STACKCHAN_DIR, "Vendor")
    STACKCHAN_DERIVED = File.join(ROOT, "build", "ios-stackchan-app")
    STACKCHAN_DEVICE_DERIVED = File.join(ROOT, "build", "ios-stackchan-app-device")

    desc "Cross-build libmruby.a (Simulator) WITH picoruby-ble + Darwin port and stage under examples/stackchan/Vendor"
    task lib: :setup do
      stage_libmruby("r2p2-picoruby-ios-stackchan-sim.rb", "ios-stackchan-sim", STACKCHAN_VENDOR)
    end

    namespace :device do
      desc "Cross-build libmruby.a (iphoneos arm64) WITH picoruby-ble + Darwin port and stage under examples/stackchan/Vendor"
      task lib: :setup do
        stage_libmruby("r2p2-picoruby-ios-stackchan-device.rb", "ios-stackchan-device", STACKCHAN_VENDOR)
      end

      desc "Build the Stack-chan app, signed, for the connected iOS device"
      task :build do
        # Target the SPECIFIC connected device (not generic/platform=iOS) so
        # -allowProvisioningUpdates can register it with the Personal Team and
        # generate a profile. Device slice is arm64; automatic signing resolves
        # the team set in examples/stackchan/project.yml.
        dest = `xcodebuild -project #{STACKCHAN_PROJ.shellescape} -scheme Stackchan -showdestinations 2>/dev/null`.lines
               .grep(/platform:iOS,/).reject { |l| l =~ /Simulator|placeholder/ }
               .first&.match(/id:(\S+)/)&.captures&.first
        raise "no connected iOS device destination (xcodebuild -showdestinations)" unless dest
        sh "xcodebuild -project #{STACKCHAN_PROJ.shellescape} -scheme Stackchan " \
           "-destination 'id=#{dest}' " \
           "-derivedDataPath #{STACKCHAN_DEVICE_DERIVED.shellescape} " \
           "ARCHS=arm64 -allowProvisioningUpdates build"
      end

      desc "Install and launch the Stack-chan app on the connected iOS device"
      task :run do
        app = Dir.glob(File.join(STACKCHAN_DEVICE_DERIVED, "Build", "Products",
                                 "*-iphoneos", "Stackchan.app")).first
        raise "app not built; run `rake ios:stackchan:device:build`" unless app
        dev = `xcrun devicectl list devices`.lines
              .grep(/iPhone|iPad/).first&.match(/([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})/)&.captures&.first
        raise "no connected iOS device (xcrun devicectl list devices)" unless dev
        sh "xcrun devicectl device install app --device #{dev} #{app.shellescape}"
        sh "xcrun devicectl device process launch --console --device #{dev} #{STACKCHAN_BUNDLE}"
      end

      desc "Full Stack-chan device pipeline: lib -> gen -> build -> run (needs a connected, signed device)"
      task all: [:lib, "ios:stackchan:gen", :build, :run]
    end

    desc "Generate the Stack-chan Xcode project from project.yml"
    task :gen do
      sh "cd #{STACKCHAN_DIR.shellescape} && xcodegen generate"
    end

    desc "Build the Stack-chan app for the iOS Simulator"
    task :build do
      # libmruby.a + the PicoBLEDarwin Swift package are arm64 only; restrict to
      # arm64 so the linker does not reject them for the x86_64 simulator slice.
      sh "xcodebuild -project #{STACKCHAN_PROJ.shellescape} " \
         "-scheme Stackchan -destination 'generic/platform=iOS Simulator' " \
         "-derivedDataPath #{STACKCHAN_DERIVED.shellescape} " \
         "ARCHS=arm64 ONLY_ACTIVE_ARCH=NO EXCLUDED_ARCHS=x86_64 build"
    end

    desc "Boot a simulator, install, and launch the Stack-chan app"
    task :run do
      app = Dir.glob(File.join(STACKCHAN_DERIVED, "Build", "Products",
                               "*-iphonesimulator", "Stackchan.app")).first
      raise "app not built; run `rake ios:stackchan:build`" unless app
      udid = `xcrun simctl list devices available`.lines
             .grep(/iPhone/).first&.match(/\(([0-9A-F-]{36})\)/)&.captures&.first
      raise "no available iPhone simulator" unless udid
      sh "xcrun simctl boot #{udid} 2>/dev/null; true"
      sh "open -a Simulator"
      sh "xcrun simctl install #{udid} #{app.shellescape}"
      sh "xcrun simctl launch #{udid} #{STACKCHAN_BUNDLE}"
    end

    desc "Full Stack-chan Simulator pipeline: lib -> gen -> build -> run"
    task all: [:lib, :gen, :build, :run]
  end

  namespace :vperiph do
    VPERIPH_DIR     = File.join(ROOT, "examples", "virtual-peripheral")
    VPERIPH_PROJ    = File.join(VPERIPH_DIR, "VirtualPeripheral.xcodeproj")
    VPERIPH_BUNDLE  = "com.bash0c7.picoruby.VirtualPeripheral"
    VPERIPH_VENDOR  = File.join(VPERIPH_DIR, "Vendor")
    VPERIPH_DERIVED = File.join(ROOT, "build", "ios-vperiph-app")
    VPERIPH_DEVICE_DERIVED = File.join(ROOT, "build", "ios-vperiph-app-device")

    desc "Cross-build libmruby.a (Simulator) WITH picoruby-ble + Darwin port and stage under examples/virtual-peripheral/Vendor"
    task lib: :setup do
      stage_libmruby("r2p2-picoruby-ios-vperiph-sim.rb", "ios-vperiph-sim", VPERIPH_VENDOR)
    end

    namespace :device do
      desc "Cross-build libmruby.a (iphoneos arm64) WITH picoruby-ble + Darwin port and stage under examples/virtual-peripheral/Vendor"
      task lib: :setup do
        stage_libmruby("r2p2-picoruby-ios-vperiph-device.rb", "ios-vperiph-device", VPERIPH_VENDOR)
      end

      desc "Build the Virtual Peripheral app, signed, for the connected iOS device"
      task :build do
        dest = `xcodebuild -project #{VPERIPH_PROJ.shellescape} -scheme VirtualPeripheral -showdestinations 2>/dev/null`.lines
               .grep(/platform:iOS,/).reject { |l| l =~ /Simulator|placeholder/ }
               .first&.match(/id:(\S+)/)&.captures&.first
        raise "no connected iOS device destination (xcodebuild -showdestinations)" unless dest
        sh "xcodebuild -project #{VPERIPH_PROJ.shellescape} -scheme VirtualPeripheral " \
           "-destination 'id=#{dest}' " \
           "-derivedDataPath #{VPERIPH_DEVICE_DERIVED.shellescape} " \
           "ARCHS=arm64 -allowProvisioningUpdates build"
      end

      desc "Install and launch the Virtual Peripheral app on the connected iOS device"
      task :run do
        app = Dir.glob(File.join(VPERIPH_DEVICE_DERIVED, "Build", "Products",
                                 "*-iphoneos", "VirtualPeripheral.app")).first
        raise "app not built; run `rake ios:vperiph:device:build`" unless app
        dev = `xcrun devicectl list devices`.lines
              .grep(/iPhone|iPad/).first&.match(/([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})/)&.captures&.first
        raise "no connected iOS device (xcrun devicectl list devices)" unless dev
        sh "xcrun devicectl device install app --device #{dev} #{app.shellescape}"
        sh "xcrun devicectl device process launch --console --device #{dev} #{VPERIPH_BUNDLE}"
      end

      desc "Full Virtual Peripheral device pipeline: lib -> gen -> build -> run (needs a connected, signed device)"
      task all: [:lib, "ios:vperiph:gen", :build, :run]
    end

    desc "Generate the Virtual Peripheral Xcode project from project.yml"
    task :gen do
      sh "cd #{VPERIPH_DIR.shellescape} && xcodegen generate"
    end

    desc "Build the Virtual Peripheral app for the iOS Simulator"
    task :build do
      sh "xcodebuild -project #{VPERIPH_PROJ.shellescape} " \
         "-scheme VirtualPeripheral -destination 'generic/platform=iOS Simulator' " \
         "-derivedDataPath #{VPERIPH_DERIVED.shellescape} " \
         "ARCHS=arm64 ONLY_ACTIVE_ARCH=NO EXCLUDED_ARCHS=x86_64 build"
    end

    desc "Boot a simulator, install, and launch the Virtual Peripheral app"
    task :run do
      app = Dir.glob(File.join(VPERIPH_DERIVED, "Build", "Products",
                               "*-iphonesimulator", "VirtualPeripheral.app")).first
      raise "app not built; run `rake ios:vperiph:build`" unless app
      udid = `xcrun simctl list devices available`.lines
             .grep(/iPhone/).first&.match(/\(([0-9A-F-]{36})\)/)&.captures&.first
      raise "no available iPhone simulator" unless udid
      sh "xcrun simctl boot #{udid} 2>/dev/null; true"
      sh "open -a Simulator"
      sh "xcrun simctl install #{udid} #{app.shellescape}"
      sh "xcrun simctl launch #{udid} #{VPERIPH_BUNDLE}"
    end

    desc "Full Virtual Peripheral Simulator pipeline: lib -> gen -> build -> run"
    task all: [:lib, :gen, :build, :run]

    desc "Build+run the macOS BLE central helper (scan PBLE-TEST, connect, write WRITE_HEX, read/subscribe) to exercise the peripheral from the Mac"
    task :write do
      src = File.join(VPERIPH_DIR, "tools", "ble_write.swift")
      bin = File.join(ROOT, "build", "ble_write")
      sh "swiftc -O #{src.shellescape} -o #{bin.shellescape}"
      # WRITE_HEX / TARGET_NAME / APP_SERVICES pass through the environment.
      sh bin.shellescape
    end
  end

  namespace :torch do
    TORCH_DIR     = File.join(ROOT, "examples", "iphone-torch")
    TORCH_PROJ    = File.join(TORCH_DIR, "Torch.xcodeproj")
    TORCH_BUNDLE  = "com.bash0c7.picoruby.Torch"
    TORCH_VENDOR  = File.join(TORCH_DIR, "Vendor")
    TORCH_DERIVED = File.join(ROOT, "build", "ios-torch-app")
    TORCH_DEVICE_DERIVED = File.join(ROOT, "build", "ios-torch-app-device")

    desc "Cross-build libmruby.a (Simulator) WITH picoruby-iphone-torch and stage under examples/iphone-torch/Vendor"
    task lib: :setup do
      stage_libmruby("r2p2-picoruby-ios-torch-sim.rb", "ios-torch-sim", TORCH_VENDOR)
    end

    desc "Generate the Torch Xcode project from project.yml"
    task :gen do
      sh "cd #{TORCH_DIR.shellescape} && xcodegen generate"
    end

    desc "Build the Torch app for the iOS Simulator"
    task :build do
      sh "xcodebuild -project #{TORCH_PROJ.shellescape} " \
         "-scheme Torch -destination 'generic/platform=iOS Simulator' " \
         "-derivedDataPath #{TORCH_DERIVED.shellescape} " \
         "ARCHS=arm64 ONLY_ACTIVE_ARCH=NO EXCLUDED_ARCHS=x86_64 build"
    end

    desc "Boot a simulator, install, and launch the Torch app"
    task :run do
      app = Dir.glob(File.join(TORCH_DERIVED, "Build", "Products",
                               "*-iphonesimulator", "Torch.app")).first
      raise "app not built; run `rake ios:torch:build`" unless app
      udid = `xcrun simctl list devices available`.lines
             .grep(/iPhone/).first&.match(/\(([0-9A-F-]{36})\)/)&.captures&.first
      raise "no available iPhone simulator" unless udid
      sh "xcrun simctl boot #{udid} 2>/dev/null; true"
      sh "open -a Simulator"
      sh "xcrun simctl install #{udid} #{app.shellescape}"
      sh "xcrun simctl launch #{udid} #{TORCH_BUNDLE}"
    end

    desc "Full Torch Simulator pipeline: lib -> gen -> build -> run"
    task all: [:lib, :gen, :build, :run]

    namespace :device do
      desc "Cross-build libmruby.a (iphoneos arm64) WITH picoruby-iphone-torch and stage under examples/iphone-torch/Vendor"
      task lib: :setup do
        stage_libmruby("r2p2-picoruby-ios-torch-device.rb", "ios-torch-device", TORCH_VENDOR)
      end

      desc "Build the Torch app, signed, for the connected iOS device"
      task :build do
        dest = `xcodebuild -project #{TORCH_PROJ.shellescape} -scheme Torch -showdestinations 2>/dev/null`.lines
               .grep(/platform:iOS,/).reject { |l| l =~ /Simulator|placeholder/ }
               .first&.match(/id:(\S+)/)&.captures&.first
        raise "no connected iOS device destination (xcodebuild -showdestinations)" unless dest
        sh "xcodebuild -project #{TORCH_PROJ.shellescape} -scheme Torch " \
           "-destination 'id=#{dest}' " \
           "-derivedDataPath #{TORCH_DEVICE_DERIVED.shellescape} " \
           "ARCHS=arm64 -allowProvisioningUpdates build"
      end

      desc "Install and launch the Torch app on the connected iOS device"
      task :run do
        app = Dir.glob(File.join(TORCH_DEVICE_DERIVED, "Build", "Products",
                                 "*-iphoneos", "Torch.app")).first
        raise "app not built; run `rake ios:torch:device:build`" unless app
        dev = `xcrun devicectl list devices`.lines
              .grep(/iPhone|iPad/).first&.match(/([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})/)&.captures&.first
        raise "no connected iOS device (xcrun devicectl list devices)" unless dev
        sh "xcrun devicectl device install app --device #{dev} #{app.shellescape}"
        sh "xcrun devicectl device process launch --console --device #{dev} #{TORCH_BUNDLE}"
      end

      desc "Full Torch device pipeline: lib -> gen -> build -> run (needs a connected, signed device)"
      task all: [:lib, "ios:torch:gen", :build, :run]
    end
  end

  namespace :net do
    NET_DIR     = File.join(ROOT, "examples", "networking")
    NET_PROJ    = File.join(NET_DIR, "Networking.xcodeproj")
    NET_BUNDLE  = "com.bash0c7.picoruby.Networking"
    NET_VENDOR  = File.join(NET_DIR, "Vendor")
    NET_DERIVED = File.join(ROOT, "build", "ios-net-app")
    NET_DEVICE_DERIVED = File.join(ROOT, "build", "ios-net-app-device")

    desc "Cross-build libmruby.a (Simulator) WITH picoruby-net (mbedTLS) and stage under examples/networking/Vendor"
    task lib: :setup do
      stage_libmruby("r2p2-picoruby-ios-net-sim.rb", "ios-net-sim", NET_VENDOR)
    end

    desc "Generate the Networking Xcode project from project.yml"
    task :gen do
      sh "cd #{NET_DIR.shellescape} && xcodegen generate"
    end

    desc "Build the Networking app for the iOS Simulator"
    task :build do
      sh "xcodebuild -project #{NET_PROJ.shellescape} " \
         "-scheme Networking -destination 'generic/platform=iOS Simulator' " \
         "-derivedDataPath #{NET_DERIVED.shellescape} " \
         "ARCHS=arm64 ONLY_ACTIVE_ARCH=NO EXCLUDED_ARCHS=x86_64 build"
    end

    desc "Boot a simulator, install, and launch the Networking app"
    task :run do
      app = Dir.glob(File.join(NET_DERIVED, "Build", "Products",
                               "*-iphonesimulator", "Networking.app")).first
      raise "app not built; run `rake ios:net:build`" unless app
      udid = `xcrun simctl list devices available`.lines
             .grep(/iPhone/).first&.match(/\(([0-9A-F-]{36})\)/)&.captures&.first
      raise "no available iPhone simulator" unless udid
      sh "xcrun simctl boot #{udid} 2>/dev/null; true"
      sh "open -a Simulator"
      sh "xcrun simctl install #{udid} #{app.shellescape}"
      sh "xcrun simctl launch #{udid} #{NET_BUNDLE}"
    end

    desc "Full Networking Simulator pipeline: lib -> gen -> build -> run"
    task all: [:lib, :gen, :build, :run]

    namespace :device do
      desc "Cross-build libmruby.a (iphoneos arm64) WITH picoruby-net and stage under examples/networking/Vendor"
      task lib: :setup do
        stage_libmruby("r2p2-picoruby-ios-net-device.rb", "ios-net-device", NET_VENDOR)
      end

      desc "Build the Networking app, signed, for the connected iOS device"
      task :build do
        dest = `xcodebuild -project #{NET_PROJ.shellescape} -scheme Networking -showdestinations 2>/dev/null`.lines
               .grep(/platform:iOS,/).reject { |l| l =~ /Simulator|placeholder/ }
               .first&.match(/id:(\S+)/)&.captures&.first
        raise "no connected iOS device destination (xcodebuild -showdestinations)" unless dest
        sh "xcodebuild -project #{NET_PROJ.shellescape} -scheme Networking " \
           "-destination 'id=#{dest}' " \
           "-derivedDataPath #{NET_DEVICE_DERIVED.shellescape} " \
           "ARCHS=arm64 -allowProvisioningUpdates build"
      end

      desc "Install and launch the Networking app on the connected iOS device"
      task :run do
        app = Dir.glob(File.join(NET_DEVICE_DERIVED, "Build", "Products",
                                 "*-iphoneos", "Networking.app")).first
        raise "app not built; run `rake ios:net:device:build`" unless app
        dev = `xcrun devicectl list devices`.lines
              .grep(/iPhone|iPad/).first&.match(/([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})/)&.captures&.first
        raise "no connected iOS device (xcrun devicectl list devices)" unless dev
        sh "xcrun devicectl device install app --device #{dev} #{app.shellescape}"
        sh "xcrun devicectl device process launch --console --device #{dev} #{NET_BUNDLE}"
      end

      desc "Full Networking device pipeline: lib -> gen -> build -> run (needs a connected, signed device)"
      task all: [:lib, "ios:net:gen", :build, :run]
    end
  end

  namespace :watch do
    WATCH_DIR     = File.join(ROOT, "examples", "watch-led-toggle")
    WATCH_PROJ    = File.join(WATCH_DIR, "WatchLEDToggle.xcodeproj")
    WATCH_BUNDLE  = "com.bash0c7.picoruby.WatchLEDToggle"
    WATCH_VENDOR  = File.join(WATCH_DIR, "Vendor")
    WATCH_DERIVED = File.join(ROOT, "build", "watchos-app")
    WATCH_DEVICE_DERIVED = File.join(ROOT, "build", "watchos-app-device")

    desc "Cross-build libmruby.a for watchOS Simulator and stage under examples/watch-led-toggle/Vendor"
    task lib: :setup do
      stage_libmruby("r2p2-picoruby-watchos-sim.rb", "watchos-sim", WATCH_VENDOR)
    end

    namespace :device do
      desc "Cross-build libmruby.a for watchOS device (arm64_32) and stage under examples/watch-led-toggle/Vendor"
      task lib: :setup do
        stage_libmruby("r2p2-picoruby-watchos-device.rb", "watchos-device", WATCH_VENDOR)
        # stage_libmruby copies the fat/arm64 archive mruby just built; the
        # physical watch needs arm64_32. Recompile in place and re-stage so
        # Vendor/lib never ends up with an arch the device can't run.
        sh "ruby #{File.join(ROOT, "build_config", "recompile_arm64_32.rb").shellescape}"
        lib = File.join(BUILD_DIR, "watchos-device", "lib", "libmruby.a")
        cp lib, File.join(WATCH_VENDOR, "lib", "libmruby.a")
        puts "Re-staged arm64_32 libmruby.a under #{WATCH_VENDOR}"
      end

      desc "Build the Watch LED Toggle app, signed, for the connected Apple Watch"
      task :build do
        dest = `xcodebuild -project #{WATCH_PROJ.shellescape} -scheme WatchLEDToggle -showdestinations 2>/dev/null`.lines
               .grep(/platform:watchOS,/).reject { |l| l =~ /Simulator|placeholder/ }
               .first&.match(/id:(\S+)/)&.captures&.first
        raise "no connected watchOS device destination (xcodebuild -showdestinations)" unless dest
        sh "xcodebuild -project #{WATCH_PROJ.shellescape} -scheme WatchLEDToggle " \
           "-destination 'id=#{dest}' " \
           "-derivedDataPath #{WATCH_DEVICE_DERIVED.shellescape} " \
           "ARCHS=arm64_32 -allowProvisioningUpdates build"
      end

      desc "Install and launch the Watch LED Toggle app on the connected Apple Watch"
      task :run do
        app = Dir.glob(File.join(WATCH_DEVICE_DERIVED, "Build", "Products",
                                 "*-watchos", "WatchLEDToggle.app")).first
        raise "app not built; run `rake ios:watch:device:build`" unless app
        dev = `xcrun devicectl list devices`.lines
              .grep(/Watch/).first&.match(/([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})/)&.captures&.first
        raise "no connected Apple Watch (xcrun devicectl list devices)" unless dev
        sh "xcrun devicectl device install app --device #{dev} #{app.shellescape}"
        sh "xcrun devicectl device process launch --console --device #{dev} #{WATCH_BUNDLE}"
      end

      desc "Full Watch device pipeline: lib -> gen -> build -> run (needs a connected, signed Apple Watch)"
      task all: [:lib, "ios:watch:gen", :build, :run]
    end

    desc "Generate the Watch LED Toggle Xcode project from project.yml"
    task :gen do
      sh "cd #{WATCH_DIR.shellescape} && xcodegen generate"
    end

    desc "Build the Watch LED Toggle app for the watchOS Simulator"
    task :build do
      sh "xcodebuild -project #{WATCH_PROJ.shellescape} " \
         "-scheme WatchLEDToggle -destination 'generic/platform=watchOS Simulator' " \
         "-derivedDataPath #{WATCH_DERIVED.shellescape} " \
         "ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build"
    end

    desc "Boot a watchOS simulator, install, and launch the Watch LED Toggle app"
    task :run do
      app = Dir.glob(File.join(WATCH_DERIVED, "Build", "Products",
                               "*-watchsimulator", "WatchLEDToggle.app")).first
      raise "app not built; run `rake ios:watch:build`" unless app
      udid = `xcrun simctl list devices available`.lines
             .grep(/Apple Watch/).first&.match(/\(([0-9A-F-]{36})\)/)&.captures&.first
      raise "no available Apple Watch simulator" unless udid
      sh "xcrun simctl boot #{udid} 2>/dev/null; true"
      sh "open -a Simulator"
      sh "xcrun simctl install #{udid} #{app.shellescape}"
      sh "xcrun simctl launch #{udid} #{WATCH_BUNDLE}"
    end

    desc "Full Watch pipeline: lib -> gen -> build -> run"
    task all: [:lib, :gen, :build, :run]
  end

  desc "Generate the Xcode project from project.yml"
  task :gen do
    sh "cd #{APP_DIR.shellescape} && xcodegen generate"
  end

  desc "Build the app for the iOS Simulator"
  task :build do
    # libmruby.a is arm64 only (cross-built for iphonesimulator/arm64).
    # Restrict xcodebuild to arm64 so the linker does not reject the library
    # when building the x86_64 slice for the generic simulator destination.
    sh "xcodebuild -project #{File.join(APP_DIR, "PicoRubyRunner.xcodeproj").shellescape} " \
       "-scheme PicoRubyRunner -destination 'generic/platform=iOS Simulator' " \
       "-derivedDataPath #{File.join(ROOT, "build", "ios-app").shellescape} " \
       "ARCHS=arm64 ONLY_ACTIVE_ARCH=NO EXCLUDED_ARCHS=x86_64 build"
  end

  desc "Boot a simulator, install, and launch the app"
  task :run do
    derived = File.join(ROOT, "build", "ios-app")
    app = Dir.glob(File.join(derived, "Build", "Products", "*-iphonesimulator", "PicoRubyRunner.app")).first
    raise "app not built; run `rake ios:build`" unless app
    udid = `xcrun simctl list devices available`.lines
           .grep(/iPhone/).first&.match(/\(([0-9A-F-]{36})\)/)&.captures&.first
    raise "no available iPhone simulator" unless udid
    sh "xcrun simctl boot #{udid} 2>/dev/null; true"
    sh "open -a Simulator"
    sh "xcrun simctl install #{udid} #{app.shellescape}"
    sh "xcrun simctl launch #{udid} #{BUNDLE_ID}"
  end

  desc "Full headless pipeline: lib -> gen -> build -> run"
  task all: [:lib, :gen, :build, :run]
end

desc "Build and launch the PicoRuby iOS Runner on the Simulator"
task ios: "ios:all"

namespace :host do
  desc "Host build of picoruby (for the bridge smoke test)"
  task lib: :setup do
    cfg = File.join(ROOT, "build_config", "r2p2-picoruby-host.rb")
    sh mruby_env(cfg), "cd #{PICORUBY_SRC.shellescape} && rake"
  end
end

desc "Compile + run the bridge smoke test on the host"
task smoke: "host:lib" do
  lib    = File.join(BUILD_DIR, "host", "lib", "libmruby.a")
  out    = "/tmp/picoruby_smoke"

  # Defines must match the host build config (r2p2-picoruby-host.rb) so the
  # bridge sees the same ABI (no-boxing, int64, estalloc, task scheduler).
  defines = %w[
    PICORB_ALLOC_ESTALLOC PICORB_ALLOC_ALIGN=8
    MRB_NO_BOXING MRB_INT64 MRB_UTF8_STRING
    PICORB_PLATFORM_DARWIN
    MRB_TICK_UNIT=4 MRB_TIMESLICE_TICK_COUNT=3
    MRB_USE_TASK_SCHEDULER=1 MRB_USE_VM_SWITCH_DISPATCH=1
  ].map { |d| "-D#{d}" }.join(" ")

  # picoruby.h uses angle-bracket includes for mrc_common.h (mruby-compiler2),
  # mruby.h (picoruby-mruby/lib/mruby), and prism.h (mruby-compiler2/lib/prism).
  # build/host/include supplies the generated presym/id.h.
  # task.h is in mruby-task/include.
  includes = [
    File.join(PICORUBY_SRC, "include"),
    File.join(PICORUBY_SRC, "mrbgems", "mruby-compiler2", "include"),
    File.join(PICORUBY_SRC, "mrbgems", "mruby-compiler2", "lib", "prism", "include"),
    File.join(PICORUBY_SRC, "mrbgems", "picoruby-mruby", "lib", "mruby", "include"),
    File.join(PICORUBY_SRC, "mrbgems", "picoruby-mruby", "include"),
    File.join(BUILD_DIR, "host", "include"),
    File.join(PICORUBY_SRC, "mrbgems", "picoruby-mruby", "lib", "mruby",
              "mrbgems", "mruby-task", "include"),
    File.join(ROOT, "bridge"),
  ].map { |p| "-I #{p.shellescape}" }.join(" ")

  sh "clang #{defines} #{includes} " \
     "#{File.join(ROOT, "bridge", "smoke_test.c").shellescape} " \
     "#{File.join(ROOT, "bridge", "picoruby_bridge.c").shellescape} " \
     "#{lib.shellescape} -o #{out.shellescape}"
  sh out
end

desc "Remove build output (keeps vendor/picoruby)"
task :clean do
  rm_rf BUILD_DIR
  rm_rf VENDOR_DIR
end

desc "Remove build output and vendor/picoruby"
task clobber: :clean do
  rm_rf PICORUBY_SRC
end
