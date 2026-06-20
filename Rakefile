require "shellwords"

ROOT          = __dir__
PICORUBY_REPO = ENV["PICORUBY_REPO"] || "https://github.com/picoruby/picoruby.git"
PICORUBY_REF  = ENV["PICORUBY_REF"]  || "master"
PICORUBY_SRC  = File.join(ROOT, "vendor", "picoruby")
BUILD_DIR     = File.join(ROOT, "build")
APP_DIR       = File.join(ROOT, "app")
VENDOR_DIR    = File.join(APP_DIR, "Vendor")
BUNDLE_ID     = "com.bash0c7.picoruby.PicoRubyRunner"

def mruby_env(cfg)
  { "MRUBY_BUILD_DIR" => BUILD_DIR, "MRUBY_CONFIG" => File.absolute_path(cfg) }
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
end

desc "Re-fetch PICORUBY_REF into the existing vendor/picoruby"
task :refresh do
  raise "vendor/picoruby absent; run `rake setup`" unless Dir.exist?(PICORUBY_SRC)
  sh "git -C #{PICORUBY_SRC.shellescape} fetch #{PICORUBY_REPO.shellescape} #{PICORUBY_REF.shellescape}"
  sh "git -C #{PICORUBY_SRC.shellescape} checkout -B #{PICORUBY_REF.shellescape} FETCH_HEAD"
  sh "git -C #{PICORUBY_SRC.shellescape} submodule update --init --recursive"
end

namespace :ios do
  desc "Cross-build libmruby.a for the iOS Simulator and stage under app/Vendor"
  task lib: :setup do
    cfg = File.join(ROOT, "build_config", "r2p2-picoruby-ios-sim.rb")
    sh mruby_env(cfg), "cd #{PICORUBY_SRC.shellescape} && rake"
    lib = File.join(BUILD_DIR, "ios-sim", "lib", "libmruby.a")
    raise "expected #{lib} not found" unless File.file?(lib)
    rm_rf VENDOR_DIR
    mkdir_p File.join(VENDOR_DIR, "lib")
    mkdir_p File.join(VENDOR_DIR, "include")
    cp lib, File.join(VENDOR_DIR, "lib", "libmruby.a")
    cp_r File.join(PICORUBY_SRC, "include", "."), File.join(VENDOR_DIR, "include")
    puts "Staged libmruby.a + headers under #{VENDOR_DIR}"
  end

  desc "Generate the Xcode project from project.yml"
  task :gen do
    sh "cd #{APP_DIR.shellescape} && xcodegen generate"
  end

  desc "Build the app for the iOS Simulator"
  task :build do
    sh "xcodebuild -project #{File.join(APP_DIR, "PicoRubyRunner.xcodeproj").shellescape} " \
       "-scheme PicoRubyRunner -destination 'generic/platform=iOS Simulator' " \
       "-derivedDataPath #{File.join(ROOT, "build", "ios-app").shellescape} build"
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
  lib = File.join(BUILD_DIR, "host", "lib", "libmruby.a")
  out = "/tmp/picoruby_smoke"
  sh "clang -I #{File.join(PICORUBY_SRC, "include").shellescape} -I #{File.join(ROOT, "bridge").shellescape} " \
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
