require "shellwords"
require "rbconfig"
require "digest"

ROOT          = __dir__
PICORUBY_REPO = ENV["PICORUBY_REPO"] || "https://github.com/bash0C7/picoruby.git"
PICORUBY_REF  = ENV["PICORUBY_REF"]  || "port-darwin"
PICORUBY_SRC  = File.join(ROOT, "vendor", "picoruby")
BUILD_DIR     = File.join(ROOT, "build")

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

# The vendored prism (picoruby -> mruby -> mrbgems/mruby-compiler-prism) ships
# its templates but not the files they generate; templates/template.rb produces
# include/prism/diagnostic.h. The host mrbc (picoruby's build_mrbc_exec hook)
# compiles prism during the presym scan, before any mrbgem.rake can run the
# generator, so on a clean clone the build aborts on the missing header.
# Generate it right after fetch. Skips when template.rb is absent (template
# layout differs) or diagnostic.h already exists (a picoruby that generates it
# itself); the generator is idempotent either way.
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

# Destination id of the SPECIFIC connected device (not generic/platform=...) so
# -allowProvisioningUpdates can register it with the Personal Team and generate
# a profile. `platform` is "iOS" or "watchOS".
def connected_destination(proj, scheme, platform)
  dest = `xcodebuild -project #{proj.shellescape} -scheme #{scheme} -showdestinations 2>/dev/null`.lines
         .grep(/platform:#{platform},/).reject { |l| l =~ /Simulator|placeholder/ }
         .first&.match(/id:(\S+)/)&.captures&.first
  raise "no connected #{platform} device destination (xcodebuild -showdestinations)" unless dest
  dest
end

# Signed device build against the connected device. Automatic signing resolves
# the team set in the example's project.yml.
def device_build(proj, scheme, derived, archs:, platform: "iOS")
  dest = connected_destination(proj, scheme, platform)
  sh "xcodebuild -project #{proj.shellescape} -scheme #{scheme} " \
     "-destination 'id=#{dest}' " \
     "-derivedDataPath #{derived.shellescape} " \
     "ARCHS=#{archs} -allowProvisioningUpdates build"
end

# Simulator build. libmruby.a (and, where present, the PicoBLEDarwin Swift
# package) are arm64 only; restrict to arm64 so the linker does not reject them
# for the x86_64 slice of the generic simulator destination.
def sim_build(proj, scheme, derived, platform: "iOS Simulator", exclude_x86_64: true)
  archs = "ARCHS=arm64 ONLY_ACTIVE_ARCH=NO"
  archs += " EXCLUDED_ARCHS=x86_64" if exclude_x86_64
  sh "xcodebuild -project #{proj.shellescape} " \
     "-scheme #{scheme} -destination 'generic/platform=#{platform}' " \
     "-derivedDataPath #{derived.shellescape} " \
     "#{archs} build"
end

# Path to the built .app under <derived>/Build/Products; raises with the build
# task to run when absent. `products_glob` selects the platform products dir
# (e.g. "*-iphonesimulator", "*-iphoneos", "*-watchos").
def built_app(derived, products_glob, app_name, build_task)
  app = Dir.glob(File.join(derived, "Build", "Products", products_glob, "#{app_name}.app")).first
  raise "app not built; run `rake #{build_task}`" unless app
  app
end

# Boot the first available simulator matching `device_label` ("iPhone" or
# "Apple Watch"), then install and launch the app.
def sim_install_launch(device_label, app, bundle_id)
  udid = `xcrun simctl list devices available`.lines
         .grep(/#{device_label}/).first&.match(/\(([0-9A-F-]{36})\)/)&.captures&.first
  raise "no available #{device_label} simulator" unless udid
  sh "xcrun simctl boot #{udid} 2>/dev/null; true"
  sh "open -a Simulator"
  sh "xcrun simctl install #{udid} #{app.shellescape}"
  sh "xcrun simctl launch #{udid} #{bundle_id}"
end

# UUID of the first connected device matching `pattern` (/iPhone|iPad/ or
# /Watch/); `label` names it in the error message. Skips "unavailable" rows
# (e.g. another of the user's devices that is paired but not present) so a
# stale pairing never shadows the device actually connected right now.
def devicectl_udid(pattern, label)
  dev = `xcrun devicectl list devices`.lines
        .grep(pattern).reject { |l| l =~ /\bunavailable\b/ }.first
        &.match(/([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})/)&.captures&.first
  raise "no connected #{label} (xcrun devicectl list devices)" unless dev
  dev
end

# Install and launch the app on the connected device via devicectl.
def device_install_launch(pattern, label, app, bundle_id)
  dev = devicectl_udid(pattern, label)
  sh "xcrun devicectl device install app --device #{dev} #{app.shellescape}"
  sh "xcrun devicectl device process launch --console --device #{dev} #{bundle_id}"
end

# Simulator kept booted and never recreated/erased, so its DiagnosticReports
# history and epoch stay stable across observe runs (env SIM_UDID overrides).
FROZEN_SIM_UDID = "022CC935-D50B-4790-978F-E4CA1DD0F5DC"

# Launch `app` on the frozen Simulator OBSERVE_N times (env, default 5) and
# classify each run OK or CRASH. `xcrun simctl launch --console-pty` is the
# only invocation found that captures both NSLog and print() output from a
# Simulator app process; it keeps streaming after the app itself is idle, so
# each run is bounded with a fixed sleep + `simctl terminate` + TERM rather
# than waited on to exit. OK requires the golden "hello 3" substring in the
# captured output AND no new crash report; CRASH is a new .ips file under
# DiagnosticReports (or, as a fallback, the estalloc crash signature showing
# up in the captured output itself even if the .ips hasn't landed yet).
# Aborts if the N runs disagree — that means an uncontrolled input is still in
# play. Raw logs land in build/observe/<name>_run<i>.txt; the first OK run's
# output is saved as build/observe/<name>_golden.txt for future runs to diff.
def observe(name, app, bundle_id)
  udid = ENV["SIM_UDID"] || FROZEN_SIM_UDID
  n    = Integer(ENV["OBSERVE_N"] || 5)
  observe_dir = File.join(BUILD_DIR, "observe")
  mkdir_p observe_dir
  golden_path = File.join(observe_dir, "#{name}_golden.txt")
  crash_dir = File.join(Dir.home, "Library", "Developer", "CoreSimulator", "Devices", udid,
                        "data", "Library", "Logs", "DiagnosticReports")

  sh "xcrun simctl install #{udid} #{app.shellescape}"

  statuses = (1..n).map do |i|
    sh "xcrun simctl terminate #{udid} #{bundle_id} 2>/dev/null; true"
    log = File.join(observe_dir, "#{name}_run#{i}.txt")
    launched_at = Time.now
    logf = File.open(log, "w")
    pid = Process.spawn("xcrun", "simctl", "launch", "--console-pty", udid, bundle_id,
                         out: logf, err: logf)
    sleep 5
    sh "xcrun simctl terminate #{udid} #{bundle_id} 2>/dev/null; true"
    sleep 1
    begin
      Process.kill("TERM", pid)
    rescue Errno::ESRCH
      # process already exited on its own between terminate and here
    end
    Process.wait(pid)
    logf.close
    output = File.read(log)

    new_crashes = Dir.glob(File.join(crash_dir, "*.ips")).select { |f| File.mtime(f) >= launched_at }
    crashed = !new_crashes.empty? || output =~ /EXC_BAD_ACCESS|est_free|remove_free_block/
    ok = !crashed && output.include?("hello 3")
    status = crashed ? :crash : (ok ? :ok : :unknown)
    detail = crashed && !new_crashes.empty? ? " (new: #{new_crashes.map { |f| File.basename(f) }.join(", ")})" : ""
    puts "run #{i}: #{status}#{detail}"

    if status == :ok
      if File.exist?(golden_path)
        puts "  GOLDEN #{File.read(golden_path) == output ? "match" : "mismatch"}"
      else
        cp log, golden_path
        puts "  golden saved: #{golden_path}"
      end
    end

    status
  end

  tally = statuses.tally
  puts "observe #{name}: #{tally} over #{n} runs"
  abort "NON-DETERMINISTIC observe: #{tally.inspect} — raw logs under #{observe_dir}" if tally.size > 1
end

desc "Verify iOS/watchOS cross-build prerequisites (host builds: rake macos:check)"
task :check do
  failures = []
  if File.directory?("/Applications/Xcode.app") &&
     system("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path", out: File::NULL, err: File::NULL)
    puts "iOS SDK:    ok"
  else
    warn "iOS SDK:    missing — install full Xcode.app (App Store); CLT alone is not enough"
    failures << "iOS SDK"
  end
  if system("which", "xcodegen", out: File::NULL, err: File::NULL)
    puts "xcodegen:   ok"
  else
    warn "xcodegen:   missing — run `brew install xcodegen`"
    failures << "xcodegen"
  end
  abort "check failed: #{failures.join(", ")}" unless failures.empty?
  puts "ok — next: rake ios (repl example on the Simulator, no signing needed)"
end

desc "Fetch picoruby into vendor/picoruby (env: PICORUBY_REPO / PICORUBY_REF; ~1.2GB with submodules)"
task :setup do
  unless Dir.exist?(PICORUBY_SRC)
    sh "git clone --recursive --branch #{PICORUBY_REF.shellescape} " \
       "#{PICORUBY_REPO.shellescape} #{PICORUBY_SRC.shellescape}"
  end
  generate_prism_templates
end

desc "Re-fetch PICORUBY_REF into the existing vendor/picoruby (env: PICORUBY_REPO / PICORUBY_REF)"
task :refresh do
  raise "vendor/picoruby absent; run `rake setup`" unless Dir.exist?(PICORUBY_SRC)
  sh "git -C #{PICORUBY_SRC.shellescape} fetch #{PICORUBY_REPO.shellescape} #{PICORUBY_REF.shellescape}"
  sh "git -C #{PICORUBY_SRC.shellescape} checkout -B #{PICORUBY_REF.shellescape} FETCH_HEAD"
  sh "git -C #{PICORUBY_SRC.shellescape} submodule update --init --recursive"
  generate_prism_templates
end

# Defines the full ios:<name> namespace for one example app:
# lib/gen/build/run/all for the Simulator plus a device:{lib,build,run,all}
# sub-namespace. Paths derive from the parameters:
#   examples/ios/<dir>/<scheme>.xcodeproj, bundle com.bash0c7.picoruby.<scheme>,
#   build_config/r2p2-picoruby-ios-<name>-{sim,device}.rb,
#   build/ios-<name>-{sim,device} (libmruby), build/ios-<name>-app{,-device}
#   (derived data). `label` names the app in task descriptions; `lib_phrase`
#   states what the libmruby build includes (`device_lib_phrase` overrides it
#   for the device lib task).
def define_ios_example(name:, label:, dir:, scheme:, lib_phrase:, device_lib_phrase: lib_phrase)
  app_dir        = File.join(ROOT, "examples", "ios", dir)
  proj           = File.join(app_dir, "#{scheme}.xcodeproj")
  bundle         = "com.bash0c7.picoruby.#{scheme}"
  vendor         = File.join(app_dir, "Vendor")
  derived        = File.join(ROOT, "build", "ios-#{name}-app")
  device_derived = File.join(ROOT, "build", "ios-#{name}-app-device")
  vendor_rel     = "examples/ios/#{dir}/Vendor"

  namespace :ios do
    namespace name do
      desc "Cross-build libmruby.a (Simulator) #{lib_phrase} and stage under #{vendor_rel} (env: IOS_MIN)"
      task lib: :setup do
        stage_libmruby("r2p2-picoruby-ios-#{name}-sim.rb", "ios-#{name}-sim", vendor)
      end

      desc "Generate the #{label} Xcode project from project.yml"
      task :gen do
        sh "cd #{app_dir.shellescape} && xcodegen generate"
      end

      desc "Build the #{label} app for the iOS Simulator"
      task :build do
        sim_build(proj, scheme, derived)
      end

      desc "Boot a simulator, install, and launch the #{label} app"
      task :run do
        app = built_app(derived, "*-iphonesimulator", scheme, "ios:#{name}:build")
        sim_install_launch("iPhone", app, bundle)
      end

      desc "Full #{label} Simulator pipeline: lib -> gen -> build -> run"
      task all: [:lib, :gen, :build, :run]

      desc "Observe #{label} launch N times on a frozen Simulator, classifying OK/CRASH (env: SIM_UDID, OBSERVE_N default 5)"
      task :observe do
        app = built_app(derived, "*-iphonesimulator", scheme, "ios:#{name}:build")
        observe(name, app, bundle)
      end

      namespace :device do
        desc "Cross-build libmruby.a (iphoneos arm64) #{device_lib_phrase} and stage under #{vendor_rel} (env: IOS_MIN)"
        task lib: :setup do
          stage_libmruby("r2p2-picoruby-ios-#{name}-device.rb", "ios-#{name}-device", vendor)
        end

        desc "Build the #{label} app, signed, for the connected iOS device"
        task :build do
          device_build(proj, scheme, device_derived, archs: "arm64")
        end

        desc "Install and launch the #{label} app on the connected iOS device"
        task :run do
          app = built_app(device_derived, "*-iphoneos", scheme, "ios:#{name}:device:build")
          device_install_launch(/iPhone|iPad/, "iOS device", app, bundle)
        end

        desc "Full #{label} device pipeline: lib -> gen -> build -> run (needs a connected, signed device)"
        task all: [:lib, "ios:#{name}:gen", :build, :run]
      end
    end
  end
end

IOS_EXAMPLES = [
  { name: "repl",      label: "PicoRuby Runner",    dir: "repl",
    scheme: "PicoRubyRunner",    lib_phrase: "WITH the full-REPL gembox" },
  { name: "stackchan", label: "Stack-chan",         dir: "stackchan",
    scheme: "Stackchan",         lib_phrase: "WITH picoruby-ble + Darwin port" },
  { name: "vperiph",   label: "Virtual Peripheral", dir: "virtual-peripheral",
    scheme: "VirtualPeripheral", lib_phrase: "WITH picoruby-ble + Darwin port" },
  { name: "torch",     label: "Torch",              dir: "iphone-torch",
    scheme: "Torch",             lib_phrase: "WITH picoruby-iphone-torch" },
  { name: "tiltsynth", label: "TiltSynth",          dir: "tilt-synth",
    scheme: "TiltSynth",         lib_phrase: "WITH the tilt-synth gems" },
  { name: "net",       label: "Networking",         dir: "networking",
    scheme: "Networking",        lib_phrase: "WITH picoruby-net (mbedTLS)",
    device_lib_phrase: "WITH picoruby-net" },
]

IOS_EXAMPLES.each { |example| define_ios_example(**example) }

# Bare ios:{lib,gen,build,run,all} and ios:device:* are aliases of ios:repl:* —
# repl is the entry-point example `rake ios` builds. No desc on purpose, so
# `rake -T` lists each pipeline once, under its example name.
namespace :ios do
  task lib: "ios:repl:lib"
  task gen: "ios:repl:gen"
  task build: "ios:repl:build"
  task run: "ios:repl:run"
  task all: "ios:repl:all"

  namespace :device do
    task lib: "ios:repl:device:lib"
    task build: "ios:repl:device:build"
    task run: "ios:repl:device:run"
    task all: "ios:repl:device:all"
  end

  namespace :vperiph do
    desc "Build+run the macOS BLE central helper (scan PBLE-TEST, connect, write WRITE_HEX, read/subscribe) to exercise the peripheral from the Mac"
    task :write do
      src = File.join(ROOT, "examples", "ios", "virtual-peripheral", "tools", "ble_write.swift")
      bin = File.join(ROOT, "build", "ble_write")
      sh "swiftc -O #{src.shellescape} -o #{bin.shellescape}"
      # WRITE_HEX / TARGET_NAME / APP_SERVICES pass through the environment.
      sh bin.shellescape
    end
  end
end

namespace :watchos do
  namespace :led do
    watch_dir            = File.join(ROOT, "examples", "watchos", "led-toggle")
    watch_proj           = File.join(watch_dir, "WatchLEDToggle.xcodeproj")
    watch_bundle         = "com.bash0c7.picoruby.WatchLEDToggle"
    watch_vendor         = File.join(watch_dir, "Vendor")
    watch_derived        = File.join(ROOT, "build", "watchos-app")
    watch_device_derived = File.join(ROOT, "build", "watchos-app-device")

    desc "Cross-build libmruby.a for watchOS Simulator and stage under examples/watchos/led-toggle/Vendor (env: WATCHOS_MIN)"
    task lib: :setup do
      stage_libmruby("r2p2-picoruby-watchos-sim.rb", "watchos-sim", watch_vendor)
    end

    desc "Generate the Watch LED Toggle Xcode project from project.yml"
    task :gen do
      sh "cd #{watch_dir.shellescape} && xcodegen generate"
    end

    desc "Build the Watch LED Toggle app for the watchOS Simulator"
    task :build do
      sim_build(watch_proj, "WatchLEDToggle", watch_derived,
                platform: "watchOS Simulator", exclude_x86_64: false)
    end

    desc "Boot a watchOS simulator, install, and launch the Watch LED Toggle app"
    task :run do
      app = built_app(watch_derived, "*-watchsimulator", "WatchLEDToggle", "watchos:led:build")
      sim_install_launch("Apple Watch", app, watch_bundle)
    end

    desc "Full Watch pipeline: lib -> gen -> build -> run"
    task all: [:lib, :gen, :build, :run]

    namespace :device do
      desc "Cross-build libmruby.a for watchOS device (arm64_32) and stage under examples/watchos/led-toggle/Vendor (env: WATCHOS_MIN)"
      task lib: :setup do
        stage_libmruby("r2p2-picoruby-watchos-device.rb", "watchos-device", watch_vendor)
        # stage_libmruby copies the fat/arm64 archive mruby just built; the
        # physical watch needs arm64_32. Recompile in place and re-stage so
        # Vendor/lib never ends up with an arch the device can't run.
        sh "ruby #{File.join(ROOT, "build_config", "recompile_arm64_32.rb").shellescape}"
        lib = File.join(BUILD_DIR, "watchos-device", "lib", "libmruby.a")
        cp lib, File.join(watch_vendor, "lib", "libmruby.a")
        puts "Re-staged arm64_32 libmruby.a under #{watch_vendor}"
      end

      desc "Build the Watch LED Toggle app, signed, for the connected Apple Watch"
      task :build do
        device_build(watch_proj, "WatchLEDToggle", watch_device_derived,
                     archs: "arm64_32", platform: "watchOS")
      end

      desc "Install and launch the Watch LED Toggle app on the connected Apple Watch"
      task :run do
        app = built_app(watch_device_derived, "*-watchos", "WatchLEDToggle", "watchos:led:device:build")
        device_install_launch(/Watch/, "Apple Watch", app, watch_bundle)
      end

      desc "Full Watch device pipeline: lib -> gen -> build -> run (needs a connected, signed Apple Watch)"
      task all: [:lib, "watchos:led:gen", :build, :run]
    end
  end
end

desc "Build and launch the repl example on the iOS Simulator (same as ios:repl:all)"
task ios: "ios:all"

desc "Default: rake ios"
task default: :ios

namespace :host do
  desc "Host build of picoruby (for the bridge smoke test)"
  task lib: :setup do
    cfg = File.join(ROOT, "build_config", "r2p2-picoruby-host.rb")
    sh mruby_env(cfg), "cd #{PICORUBY_SRC.shellescape} && rake"
  end
end

# Content hash of a static archive's members, ignoring `ar` header metadata
# (mtime/uid/gid) that varies build-to-build even when the compiled code is
# identical. Used by determinism:ios:repl so the gate reflects real code/input
# drift instead of archive-header noise.
def libmruby_content_hash(lib)
  require "tmpdir"
  Dir.mktmpdir do |d|
    sh "cd #{d.shellescape} && ar x #{lib.shellescape}"
    members = Dir.glob(File.join(d, "*")).sort
    Digest::SHA256.hexdigest(
      members.map { |f| "#{File.basename(f)}:#{Digest::SHA256.file(f).hexdigest}" }.join("\n")
    )
  end
end

# Deterministic-build verification: the same (commit, build_config, vendor tree)
# must produce libmruby.a with byte-identical object content. Guards against
# the "100KB drift" where an unnoticed input change silently altered the
# archive; hashes extracted members rather than the raw .a so `ar` header
# timestamps/uid/gid (which vary every build regardless of code) don't cause
# false positives.
namespace :determinism do
  namespace :ios do
    desc "Verify ios-repl libmruby.a has byte-identical object content across two clean builds"
    task :repl do
      lib = File.join(BUILD_DIR, "ios-repl-sim", "lib", "libmruby.a")
      hashes = (1..2).map do |i|
        rm_rf File.join(BUILD_DIR, "ios-repl-sim")
        Rake::Task["setup"].reenable
        Rake::Task["ios:repl:lib"].reenable
        Rake::Task["ios:repl:lib"].invoke
        h = libmruby_content_hash(lib)
        puts "build #{i}: #{h}"
        h
      end
      if hashes.uniq.size == 1
        puts "DETERMINISTIC ok: #{hashes.first}"
      else
        abort "NON-DETERMINISTIC: #{hashes.inspect} — investigate embedded timestamps/paths/ar ordering"
      end
    end
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

  # picoruby.h uses angle-bracket includes for mrc_common.h (mruby-compiler),
  # mruby.h (picoruby-mruby/lib/mruby), and prism.h (mruby-compiler/lib/prism).
  # build/host/include supplies the generated presym/id.h.
  # task.h is in mruby-task/include.
  includes = [
    File.join(PICORUBY_SRC, "include"),
    File.join(PICORUBY_SRC, "mrbgems", "mruby-compiler", "include"),
    File.join(PICORUBY_SRC, "mrbgems", "mruby-compiler", "lib", "prism", "include"),
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

desc "Remove build output and every example's staged Vendor (keeps vendor/picoruby)"
task :clean do
  rm_rf BUILD_DIR
  Dir.glob(File.join(ROOT, "examples", "*", "*", "Vendor")).each { |dir| rm_rf dir }
end

desc "Remove build output and vendor/picoruby"
task clobber: :clean do
  rm_rf PICORUBY_SRC
end
