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

# What a build/<name>/ directory was produced from: the picoruby tree it
# compiled and the build_config that drove it. build_config files are
# self-contained (none require another), so the config's own digest is the whole
# story for the config side.
def build_stamp(config_basename)
  cfg = File.join(ROOT, "build_config", config_basename)
  sha = if File.directory?(File.join(PICORUBY_SRC, ".git"))
          `git -C #{PICORUBY_SRC.shellescape} rev-parse HEAD`.strip
        else
          ""
        end
  Digest::SHA256.hexdigest("#{sha}\n#{Digest::SHA256.file(cfg).hexdigest}")
end

# mruby's compile rule rebuilds an object only when its .c is newer, so a
# build/<name>/ left from an earlier picoruby or an earlier build_config
# survives both untouched. `rake refresh` is the trap: a freshly fetched tree's
# files can carry mtimes OLDER than the .o files already in build/, so every
# object looks up to date, nothing recompiles, and the lib task reports success
# while staging the previous picoruby's archive. The app then fails to link
# against a symbol that moved — the error names the symbol, never the stale
# directory. Stamp each build dir with its inputs and wipe it when they change.
def invalidate_stale_build(config_basename, build_name)
  want  = build_stamp(config_basename)
  dir   = File.join(BUILD_DIR, build_name)
  stamp = File.join(dir, ".r2p2-build-stamp")
  if File.directory?(dir) && (!File.file?(stamp) || File.read(stamp).strip != want)
    puts "build/#{build_name}: picoruby or build_config changed since it was built — rebuilding from scratch"
    rm_rf dir
  end
  want
end

# Cross-build libmruby.a with the given build_config and stage the archive +
# picoruby headers under <vendor_dir>. `build_name` is the MRuby build name (the
# build/<name>/ output dir). Shared by each example's lib task.
def stage_libmruby(config_basename, build_name, vendor_dir)
  stamp = invalidate_stale_build(config_basename, build_name)
  cfg = File.join(ROOT, "build_config", config_basename)
  sh mruby_env(cfg), "cd #{PICORUBY_SRC.shellescape} && rake"
  File.write(File.join(BUILD_DIR, build_name, ".r2p2-build-stamp"), stamp)
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
# -allowProvisioningUpdates + -allowProvisioningDeviceRegistration can register
# it with the team and generate a profile. `platform` is "iOS" or "watchOS".
# Names of the devices devicectl reports as "connected" right now. A paired
# but absent device is "available (paired)", and a stale one "unavailable";
# neither can take an install, so both helpers below prefer this set.
def devicectl_connected_names
  `xcrun devicectl list devices`.lines.grep(/\bconnected\b/).map { |l| l.split(/\s{2,}/).first.to_s.strip }
end

# DEVICE_NAME pins which paired device the device: tasks target, matched as a
# substring of the name devicectl and xcodebuild print. Needed whenever more
# than one device of a platform is paired and none of them reports "connected":
# the fallbacks below then choose by list order, which is arbitrary and readily
# lands on a device that is locked, absent, or simply the wrong one.
def device_name_filter(rows)
  want = ENV["DEVICE_NAME"]
  return rows if want.nil? || want.empty?
  picked = rows.select { |row| row.include?(want) }
  raise "DEVICE_NAME=#{want.inspect} matches none of:\n#{rows.join}" if picked.empty?
  picked
end

def connected_destination(proj, scheme, platform)
  lines = `xcodebuild -project #{proj.shellescape} -scheme #{scheme} -showdestinations 2>/dev/null`.lines
          .grep(/platform:#{platform},/).reject { |l| l =~ /Simulator|placeholder/ }
  lines = device_name_filter(lines)
  connected = devicectl_connected_names
  line = lines.find { |l| connected.any? { |n| l.include?("name:#{n}") } } ||
         lines.find { |l| l !~ /error:/ } || lines.first
  dest = line&.match(/id:(\S+?),?\s/)&.captures&.first
  raise "no connected #{platform} device destination (xcodebuild -showdestinations)" unless dest
  dest
end

# Signed device build against the connected device. Automatic signing resolves
# the team set in the example's project.yml. -allowProvisioningUpdates alone
# only refreshes profiles/certificates; registering a device the team has not
# seen (or whose Personal Team registration has expired) additionally needs
# -allowProvisioningDeviceRegistration (see `xcodebuild -help`).
def device_build(proj, scheme, derived, archs:, platform: "iOS")
  dest = connected_destination(proj, scheme, platform)
  sh "xcodebuild -project #{proj.shellescape} -scheme #{scheme} " \
     "-destination 'id=#{dest}' " \
     "-derivedDataPath #{derived.shellescape} " \
     "ARCHS=#{archs} -allowProvisioningUpdates " \
     "-allowProvisioningDeviceRegistration build"
end

# Unsigned generic-device build: compiles and links the device app against
# the device libmruby.a with no connected device and no signing identity, so
# device-SDK-only breakage (an API the device SDK marks unavailable, a port
# symbol missing from the device archive) surfaces before the signing/install
# session. Signing and install stay with `device:build` / `device:run`.
def device_check_build(proj, scheme, derived, archs:, platform: "iOS")
  sh "xcodebuild -project #{proj.shellescape} -scheme #{scheme} " \
     "-destination 'generic/platform=#{platform}' " \
     "-derivedDataPath #{derived.shellescape} " \
     "ARCHS=#{archs} CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build"
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

# UDID of an available simulator for `device_label` ("iPhone" or "Apple
# Watch"). iPhone prefers the model named by SIM_NAME (default "iPhone 16e",
# the phone the examples are exercised on, so the Simulator matches the real
# screen) and falls back to the first available iPhone with a warning.
SIM_NAME = ENV["SIM_NAME"] || "iPhone 16e"

def first_available_sim(device_label)
  lines = `xcrun simctl list devices available`.lines.grep(/#{device_label}/)
  pick  = ->(l) { l&.match(/\(([0-9A-F-]{36})\)/)&.captures&.first }
  if device_label == "iPhone"
    udid = pick.(lines.find { |l| l.strip.start_with?("#{SIM_NAME} (") })
    return udid if udid
    warn "no #{SIM_NAME.inspect} simulator; using the first available iPhone (set SIM_NAME to pin one)"
  end
  udid = pick.(lines.first)
  raise "no available #{device_label} simulator" unless udid
  udid
end

# Boot the first available simulator matching `device_label` ("iPhone" or
# "Apple Watch"), then install and launch the app.
def sim_install_launch(device_label, app, bundle_id)
  udid = first_available_sim(device_label)
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
  rows = device_name_filter(
    `xcrun devicectl list devices`.lines.grep(pattern).reject { |l| l =~ /\bunavailable\b/ }
  )
  dev = (rows.find { |l| l =~ /\bconnected\b/ } || rows.first)
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
FROZEN_SIM_UDID = "A38F6094-C80A-4670-9798-C101B2F38821"   # the iPhone 16e simulator

# Launch `app` on the frozen Simulator OBSERVE_N times (env, default 5) and
# classify each run OK or CRASH. `xcrun simctl launch --console-pty` is the
# only invocation found that captures both NSLog and print() output from a
# Simulator app process; it keeps streaming after the app itself is idle, so
# each run is bounded with a fixed sleep + `simctl terminate` + TERM rather
# than waited on to exit. OK requires the example's `golden:` substring in the
# captured output AND no new crash report; CRASH is a new .ips file under the
# HOST's ~/Library/Logs/DiagnosticReports (Simulator app crashes land there,
# not under the per-device CoreSimulator data path — that path doesn't even
# exist on hosts that have never had a crash reported through it) whose
# filename starts with the app's process name (the bundle id's last
# component, e.g. "PicoRubyRunner") and whose mtime is at/after this run's
# launch time (so a report from a previous run isn't double-counted), or, as
# a fallback, the estalloc crash signature showing up in the captured output
# itself even if the .ips hasn't landed yet.
# Aborts if the N runs disagree — that means an uncontrolled input is still in
# play. Raw logs land in build/observe/<name>_run<i>.txt; the first OK run's
# output is saved as build/observe/<name>_golden.txt for future runs to diff.
def observe(name, app, bundle_id, golden:)
  udid = ENV["SIM_UDID"] || FROZEN_SIM_UDID
  unless `xcrun simctl list devices available`.include?(udid)
    udid = first_available_sim("iPhone")
    warn "observe: frozen simulator not on this host; using #{udid} (set SIM_UDID to pin one)"
  end
  n    = Integer(ENV["OBSERVE_N"] || 5)
  observe_dir = File.join(BUILD_DIR, "observe")
  mkdir_p observe_dir
  golden_path = File.join(observe_dir, "#{name}_golden.txt")
  crash_dir = File.expand_path("~/Library/Logs/DiagnosticReports")
  process_name = bundle_id.split(".").last

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

    new_crashes = Dir.exist?(crash_dir) ? Dir.glob(File.join(crash_dir, "*.ips")).select { |f|
      File.basename(f).start_with?("#{process_name}-") && File.mtime(f) >= launched_at
    } : []
    crashed = !new_crashes.empty? || output =~ /EXC_BAD_ACCESS|est_free|remove_free_block/
    # A Ruby exception at boot leaves the VM open (the bridge prints the
    # backtrace and carries on), so the golden line can still appear; the
    # backtrace header is the tell.
    ruby_error = output.include?("trace (most recent call last)")
    ok = !crashed && !ruby_error && output.include?(golden)
    status = crashed ? :crash : (ruby_error ? :ruby_error : (ok ? :ok : :unknown))
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
def define_ios_example(name:, label:, dir:, scheme:, lib_phrase:, golden:, device_lib_phrase: lib_phrase)
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
        observe(name, app, bundle, golden: golden)
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

        desc "Link the #{label} app for a generic iOS device without signing (no device needed)"
        task :check do
          device_check_build(proj, scheme, device_derived, archs: "arm64")
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

# golden: substring `ios:<name>:observe` requires in the console-pty output of a
# launch (each example's VMExecutor.swift NSLogs "[<Label>] VM opened" after
# vm_open; repl prints its default snippet's result).
IOS_EXAMPLES = [
  { name: "repl",      label: "PicoRuby Runner",    dir: "repl",
    scheme: "PicoRubyRunner",    lib_phrase: "WITH the full-REPL gembox",
    golden: "hello 3" },
  { name: "stackchan", label: "Stack-chan",         dir: "stackchan",
    scheme: "Stackchan",         lib_phrase: "WITH picoruby-ble + Darwin port",
    golden: "[Stackchan] VM opened" },
  { name: "vperiph",   label: "Virtual Peripheral", dir: "virtual-peripheral",
    scheme: "VirtualPeripheral", lib_phrase: "WITH picoruby-ble + Darwin port",
    golden: "[VirtualPeripheral] VM opened" },
  { name: "torch",     label: "Torch",              dir: "iphone-torch",
    scheme: "Torch",             lib_phrase: "WITH picoruby-iphone-torch",
    golden: "[Torch] VM starting" },
  { name: "tiltsynth", label: "TiltSynth",          dir: "tilt-synth",
    scheme: "TiltSynth",         lib_phrase: "WITH the tilt-synth gems",
    golden: "[TiltSynth] VM opened" },
  { name: "net",       label: "Networking",         dir: "networking",
    scheme: "Networking",        lib_phrase: "WITH picoruby-net-http (mbedTLS)",
    device_lib_phrase: "WITH picoruby-net-http",
    golden: "handshake OK" },   # app.rb auto-fetches once at boot (VMExecutor.swift)
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
        sh "ruby #{File.join(ROOT, "build_config", "recompile_arm64_32.rb").shellescape} " \
           "watchos-device r2p2-picoruby-watchos-device.rb"
        lib = File.join(BUILD_DIR, "watchos-device", "lib", "libmruby.a")
        cp lib, File.join(watch_vendor, "lib", "libmruby.a")
        puts "Re-staged arm64_32 libmruby.a under #{watch_vendor}"
      end

      desc "Build the Watch LED Toggle app, signed, for the connected Apple Watch"
      task :build do
        device_build(watch_proj, "WatchLEDToggle", watch_device_derived,
                     archs: "arm64_32", platform: "watchOS")
      end

      desc "Link the Watch LED Toggle app for a generic watchOS device without signing (no watch needed)"
      task :check do
        device_check_build(watch_proj, "WatchLEDToggle", watch_device_derived,
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

  namespace :stackchan do
    ws_dir            = File.join(ROOT, "examples", "watchos", "stackchan")
    ws_proj           = File.join(ws_dir, "WatchStackchan.xcodeproj")
    ws_bundle         = "com.bash0c7.picoruby.WatchStackchan"
    ws_vendor         = File.join(ws_dir, "Vendor")
    ws_derived        = File.join(ROOT, "build", "watchos-stackchan-app")
    ws_device_derived = File.join(ROOT, "build", "watchos-stackchan-app-device")

    desc "Cross-build libmruby.a for watchOS Simulator (BLE) and stage under examples/watchos/stackchan/Vendor (env: WATCHOS_MIN)"
    task lib: :setup do
      stage_libmruby("r2p2-picoruby-watchos-stackchan-sim.rb", "watchos-stackchan-sim", ws_vendor)
    end

    desc "Generate the Watch Stack-chan Xcode project from project.yml"
    task :gen do
      sh "cd #{ws_dir.shellescape} && xcodegen generate"
    end

    desc "Build the Watch Stack-chan app for the watchOS Simulator"
    task :build do
      sim_build(ws_proj, "WatchStackchan", ws_derived,
                platform: "watchOS Simulator", exclude_x86_64: false)
    end

    desc "Boot a watchOS simulator, install, and launch the Watch Stack-chan app"
    task :run do
      app = built_app(ws_derived, "*-watchsimulator", "WatchStackchan", "watchos:stackchan:build")
      sim_install_launch("Apple Watch", app, ws_bundle)
    end

    desc "Full Watch Stack-chan pipeline: lib -> gen -> build -> run"
    task all: [:lib, :gen, :build, :run]

    namespace :device do
      desc "Cross-build libmruby.a for watchOS device (arm64_32, BLE) and stage under examples/watchos/stackchan/Vendor (env: WATCHOS_MIN)"
      task lib: :setup do
        stage_libmruby("r2p2-picoruby-watchos-stackchan-device.rb", "watchos-stackchan-device", ws_vendor)
        # stage_libmruby copies the fat/arm64 archive mruby just built; the
        # physical watch needs arm64_32. Recompile in place and re-stage so
        # Vendor/lib never ends up with an arch the device can't run.
        sh "ruby #{File.join(ROOT, "build_config", "recompile_arm64_32.rb").shellescape} " \
           "watchos-stackchan-device r2p2-picoruby-watchos-stackchan-device.rb"
        lib = File.join(BUILD_DIR, "watchos-stackchan-device", "lib", "libmruby.a")
        cp lib, File.join(ws_vendor, "lib", "libmruby.a")
        puts "Re-staged arm64_32 libmruby.a under #{ws_vendor}"
      end

      desc "Build the Watch Stack-chan app, signed, for the connected Apple Watch"
      task :build do
        device_build(ws_proj, "WatchStackchan", ws_device_derived,
                     archs: "arm64_32", platform: "watchOS")
      end

      desc "Link the Watch Stack-chan app for a generic watchOS device without signing (no watch needed)"
      task :check do
        device_check_build(ws_proj, "WatchStackchan", ws_device_derived,
                           archs: "arm64_32", platform: "watchOS")
      end

      desc "Install and launch the Watch Stack-chan app on the connected Apple Watch"
      task :run do
        app = built_app(ws_device_derived, "*-watchos", "WatchStackchan", "watchos:stackchan:device:build")
        device_install_launch(/Watch/, "Apple Watch", app, ws_bundle)
      end

      desc "Full Watch Stack-chan device pipeline: lib -> gen -> build -> run (needs a connected, signed Apple Watch)"
      task all: [:lib, "watchos:stackchan:gen", :build, :run]
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

# ---- regression sweep -------------------------------------------------------
#
# Every example, in one command. The iOS half is derived from IOS_EXAMPLES, so a
# new iOS example joins the sweep by being declared there. The watchOS
# namespaces are written out by hand in this file, so they are listed by hand
# here too — add a watchOS example and this list is the one place to extend.
REGRESSION_EXAMPLES = IOS_EXAMPLES.map { |e| "ios:#{e[:name]}" } +
                      %w[watchos:led watchos:stackchan]

REGRESS_LOG_DIR = File.join(BUILD_DIR, "regress")

# Run each rake task in its own process, keep going past failures, and report
# once at the end. A sweep that aborts on the first failure hides every problem
# behind it, which is the opposite of what a regression run is for. Per-step
# logs land under build/regress/ so a failure is diagnosable without re-running
# the whole matrix; CI uploads that directory.
def regress(steps)
  mkdir_p REGRESS_LOG_DIR
  results = steps.map do |task|
    log = File.join(REGRESS_LOG_DIR, "#{task.tr(':', '_')}.log")
    ok  = system("cd #{ROOT.shellescape} && rake #{task} > #{log.shellescape} 2>&1")
    puts format("%-42s %s", task, ok ? "PASS" : "FAIL")
    $stdout.flush
    [task, ok, log]
  end

  failed = results.reject { |_, ok, _| ok }
  failed.each do |task, _, log|
    puts "\n===== #{task} FAILED — last 30 lines of #{log} ====="
    puts File.readlines(log).last(30).join
  end
  puts "\n#{results.length - failed.length}/#{results.length} passed"
  abort "regression failed: #{failed.map(&:first).join(', ')}" unless failed.empty?
end

namespace :regress do
  desc "Host-only checks: every example's standalone unit test + the bridge smoke test (no Xcode, no Simulator)"
  task :unit do
    tests = Dir.glob(File.join(ROOT, "examples", "**", "test_*.rb")).sort
    abort "no examples/**/test_*.rb found — the glob or the example layout moved" if tests.empty?
    mkdir_p REGRESS_LOG_DIR
    results = tests.map do |test|
      rel = test.sub("#{ROOT}/", "")
      log = File.join(REGRESS_LOG_DIR, "#{rel.tr('/', '_')}.log")
      ok  = system(RbConfig.ruby, test, out: log, err: [:child, :out])
      puts format("%-42s %s", rel, ok ? "PASS" : "FAIL")
      [rel, ok, log]
    end

    failed = results.reject { |_, ok, _| ok }
    failed.each { |rel, _, log| puts "\n===== #{rel} FAILED =====\n#{File.read(log)}" }
    abort "unit tests failed: #{failed.map(&:first).join(', ')}" unless failed.empty?

    # Shelled out like every other sweep step so `smoke` resolves its own
    # host:lib dependency in a clean process.
    regress(["smoke"])
  end

  desc "Link every example for a real device without signing (no device needed)"
  task :device do
    regress(REGRESSION_EXAMPLES.flat_map { |ns| ["#{ns}:device:lib", "#{ns}:gen", "#{ns}:device:check"] })
  end

  desc "Build every example for the Simulator"
  task :sim do
    regress(REGRESSION_EXAMPLES.flat_map { |ns| ["#{ns}:lib", "#{ns}:gen", "#{ns}:build"] })
  end

  desc "Link and build ONE example (env: EXAMPLE=ios:torch) — the unit the CI regression matrix fans out over"
  task :one do
    ns = ENV["EXAMPLE"].to_s
    unless REGRESSION_EXAMPLES.include?(ns)
      abort "EXAMPLE=#{ns.inspect} is not one of: #{REGRESSION_EXAMPLES.join(', ')}"
    end
    regress(["#{ns}:device:lib", "#{ns}:gen", "#{ns}:device:check",
             "#{ns}:lib", "#{ns}:gen", "#{ns}:build"])
  end

  # Emits the example list as JSON so .github/workflows/regression.yml can build
  # its matrix from it. Keeps IOS_EXAMPLES the single place an example is
  # declared — a new example joins CI without anyone editing the workflow.
  # No desc: it is plumbing, not something to run by hand.
  task :examples do
    require "json"
    puts JSON.generate(REGRESSION_EXAMPLES)
  end
end

# Order is load-bearing. Each example's device:lib and lib overwrite the SAME
# examples/<platform>/<name>/Vendor/lib/libmruby.a, so the device sweep must
# finish before the Simulator sweep, and the Simulator sweep must run last —
# that leaves every Vendor holding the arch `rake <example>:run` needs.
desc "Full regression: unit tests, then device link checks, then Simulator builds, for every example"
task regress: ["regress:unit", "regress:device", "regress:sim", "macos:build"]

desc "Compile + run the bridge smoke test on the host"
task smoke: "host:lib" do
  lib    = File.join(BUILD_DIR, "host", "lib", "libmruby.a")
  out    = "/tmp/picoruby_smoke"

  # Defines must match what the host build (r2p2-picoruby-host.rb) compiled
  # libmruby.a with, so the bridge sees the same ABI (no-boxing, int64,
  # estalloc, task scheduler). MRB_BASELINE_PROFILE=1 is not in the config:
  # picoruby-mruby adds it build-wide whenever PICORB_PLATFORM_POSIX is set,
  # and it changes sizeof(mrb_state). Audit against the `-D` flags of a
  # `rake -v` build log when either side changes.
  defines = %w[
    PICORB_ALLOC_ESTALLOC PICORB_ALLOC_ALIGN=8
    MRB_NO_BOXING MRB_INT64 MRB_UTF8_STRING
    PICORB_PLATFORM_POSIX PICORB_PLATFORM_DARWIN
    MRB_BASELINE_PROFILE=1
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
