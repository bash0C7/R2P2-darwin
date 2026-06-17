# R2P2-macOS — environment to build & run standard PicoRuby / R2P2 on macOS host.
#
# Mechanism: fetch picoruby from GitHub (NO submodule, NO sibling-checkout build)
# into vendor/picoruby via `rake setup`, then build it with our MRUBY_CONFIG,
# redirecting ALL output into ./build* via MRUBY_BUILD_DIR so the fetched source
# stays pristine.
#
#   PICORUBY_REPO  default upstream picoruby/picoruby; override to verify a fork
#                  branch (e.g. the local bash0C7/picoruby that holds a PR branch).
#   PICORUBY_REF   default master; set to a branch/tag to verify a PR.
#
# macOS env the upstream build requires: rbenv Ruby 4.0.5 + Homebrew openssl@3.
#
# Usage:
#   rake setup                              clone picoruby into vendor/picoruby
#   rake          / rake build              standard r2p2 + picoruby -> ./build
#   rake build:ble                          picoruby-ble + Darwin port -> ./build-ble
#   rake run [APP=x.rb]                     run r2p2 shell (or picoruby APP)
#   rake run:ble APP=x.rb                   run an app on the BLE runtime
#   rake clean                              remove build outputs
#   rake clobber                            also remove vendor/picoruby

require "shellwords"

R2P2_MACOS_ROOT = __dir__
PICORUBY_REPO   = ENV["PICORUBY_REPO"] || "https://github.com/picoruby/picoruby.git"
PICORUBY_REF    = ENV["PICORUBY_REF"] || "master"
PICORUBY_SRC    = File.join(R2P2_MACOS_ROOT, "vendor", "picoruby")
BUILD_RUBY      = "4.0.5"

DEFAULT_CONFIG  = File.join(R2P2_MACOS_ROOT, "build_config", "default.rb")
DEFAULT_BUILD   = File.join(R2P2_MACOS_ROOT, "build")
BLE_CONFIG      = File.join(R2P2_MACOS_ROOT, "build_config", "ble.rb")
BLE_BUILD       = File.join(R2P2_MACOS_ROOT, "build-ble")

def openssl_prefix
  prefix = `brew --prefix openssl@3 2>/dev/null`.strip
  raise "openssl@3 not found. Run: brew install openssl@3" if prefix.empty?
  prefix
end

# Pin rbenv Ruby 4.0.5 regardless of any ambient version.
def build_env
  {
    "PATH"          => "#{Dir.home}/.rbenv/shims:#{ENV['PATH']}",
    "RBENV_VERSION" => BUILD_RUBY,
  }
end

# Build via upstream's DEFAULT rake task so it honors our MRUBY_CONFIG; all
# output is redirected into build_dir, leaving the fetched source pristine.
# NB: do NOT use `picoruby:prod` — it hardcodes MRUBY_CONFIG=default.
def build_runtime(config:, build_dir:, bins:, label:)
  ssl = openssl_prefix
  cmd = "cd #{PICORUBY_SRC.shellescape} && " \
        "rake LDFLAGS=-L#{ssl}/lib CFLAGS=-I#{ssl}/include"
  sh build_env.merge("MRUBY_CONFIG" => config, "MRUBY_BUILD_DIR" => build_dir), cmd
  bins.each { |bin| raise "build finished but #{bin} is missing" unless File.executable?(bin) }
  bins.each { |bin| puts "Built: #{bin}" }
end

desc "Fetch picoruby from PICORUBY_REPO (default upstream) into vendor/picoruby at PICORUBY_REF (default master)"
task :setup do
  unless Dir.exist?(PICORUBY_SRC)
    sh "git clone --recursive --branch #{PICORUBY_REF.shellescape} " \
       "#{PICORUBY_REPO.shellescape} #{PICORUBY_SRC.shellescape}"
  end
  # No `bundle install`: the host build uses bare `rake`; its deps (prism etc.)
  # are git submodules pulled by --recursive, and rake is a default gem.
end

desc "Dev loop: re-fetch PICORUBY_REF into the existing vendor/picoruby (no re-clone)"
task :refresh do
  raise "vendor/picoruby absent; run `rake build` first" unless Dir.exist?(PICORUBY_SRC)
  sh "git -C #{PICORUBY_SRC.shellescape} fetch #{PICORUBY_REPO.shellescape} #{PICORUBY_REF.shellescape}"
  sh "git -C #{PICORUBY_SRC.shellescape} checkout -B #{PICORUBY_REF.shellescape} FETCH_HEAD"
  sh "git -C #{PICORUBY_SRC.shellescape} submodule update --init --recursive"
end

desc "Build standard r2p2 + picoruby host runtime into ./build"
task build: :setup do
  build_runtime(config: DEFAULT_CONFIG, build_dir: DEFAULT_BUILD, label: "",
                bins: [File.join(DEFAULT_BUILD, "host", "bin", "r2p2"),
                       File.join(DEFAULT_BUILD, "host", "bin", "picoruby")])
end

desc "Build the BLE host runtime (picoruby-ble + Darwin/CoreBluetooth port) into ./build-ble"
task "build:ble" => :setup do
  build_runtime(config: BLE_CONFIG, build_dir: BLE_BUILD, label: " (ble)",
                bins: [File.join(BLE_BUILD, "host", "bin", "picoruby")])
end

desc "Run the r2p2 shell, or a Ruby app on the picoruby runner (APP=path/to.rb)"
task :run do
  r2p2 = File.join(DEFAULT_BUILD, "host", "bin", "r2p2")
  pr   = File.join(DEFAULT_BUILD, "host", "bin", "picoruby")
  if (app = ENV["APP"])
    raise "Not built. Run `rake build` first." unless File.executable?(pr)
    exec({}, pr, app)
  else
    raise "Not built. Run `rake build` first." unless File.executable?(r2p2)
    exec({}, r2p2)
  end
end

desc "Run a Ruby app on the BLE runtime (APP=path/to.rb)"
task "run:ble" do
  pr = File.join(BLE_BUILD, "host", "bin", "picoruby")
  raise "Not built. Run `rake build:ble` first." unless File.executable?(pr)
  exec({}, pr, ENV["APP"] || raise("set APP=path/to.rb"))
end

desc "Remove build outputs (keeps fetched vendor/picoruby)"
task :clean do
  rm_rf DEFAULT_BUILD
  rm_rf BLE_BUILD
end

desc "Remove build outputs and the fetched vendor/picoruby"
task clobber: :clean do
  rm_rf PICORUBY_SRC
end

task default: :build
