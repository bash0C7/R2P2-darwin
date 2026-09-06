#!/usr/bin/env ruby
# Recompile arm64 objects in a watchOS device build dir as arm64_32
# and create a proper arm64_32 libmruby.a for watchOS device.
#
# Run from worktree root:
#   ruby build_config/recompile_arm64_32.rb [build_name] [config_basename]
#
# Defaults keep the led-toggle invocation working unchanged:
#   build_name       "watchos-device"
#   config_basename  "r2p2-picoruby-watchos-device.rb"
#
# The Stack-chan watch example passes its own pair:
#   ruby build_config/recompile_arm64_32.rb \
#     watchos-stackchan-device r2p2-picoruby-watchos-stackchan-device.rb

require 'shellwords'

BUILD_NAME      = ARGV[0] || "watchos-device"
CONFIG_BASENAME = ARGV[1] || "r2p2-picoruby-watchos-device.rb"

ROOT      = File.expand_path("..", __dir__)
BUILD_DIR = File.join(ROOT, "build", BUILD_NAME)
SDK       = `xcrun --sdk watchos --show-sdk-path`.strip
CLANG     = `xcrun --sdk watchos --find clang`.strip
AR        = `xcrun --sdk watchos --find ar`.strip

raise "build dir not found: #{BUILD_DIR} (run the device lib task first)" unless Dir.exist?(BUILD_DIR)
puts "Recompiling #{BUILD_NAME} against #{CONFIG_BASENAME}"

# Single source of truth: read the cc.defines straight from the device
# build_config so the arm64_32 recompile can never drift from what `rake
# watchos:led:device:lib` compiled the other objects with. A mismatch here
# (esp. MRB_INT64 / MRB_NO_BOXING) yields a libmruby.a whose objects disagree
# on the mrb_value layout — a silent on-device corruption.
CONFIG_RB = File.join(__dir__, CONFIG_BASENAME)
config_src = File.read(CONFIG_RB)
defs = config_src.scan(/conf\.cc\.defines\s*<<\s*"([^"]+)"/).flatten
raise "no cc.defines found in #{CONFIG_RB}" if defs.empty?
puts "Defines from build_config (#{defs.size}): #{defs.join(' ')}"

# Defines the gems add build-wide, which the config file cannot show: the VM
# selector and task scheduler from conf.picoruby / mruby-task, and the profile
# picoruby-mruby derives from PICORB_PLATFORM_POSIX (it changes
# sizeof(mrb_state), so every object must agree). Keep in step with
# vendor/picoruby/lib/picoruby/build.rb and picoruby-mruby/mrbgem.rake.
unless defs.include?("PICORB_PLATFORM_POSIX")
  raise "#{CONFIG_RB} must define PICORB_PLATFORM_POSIX (Darwin is POSIX)"
end
# HAVE_MRUBY_IO_GEM comes from mruby-io (build-wide), NDEBUG from picoruby's
# non-debug build (lib/picoruby/build.rb).
gem_defs = %w[PICORB_VM_MRUBY MRB_USE_TASK_SCHEDULER MRB_BASELINE_PROFILE=1 HAVE_MRUBY_IO_GEM NDEBUG=1]

# picoruby-mbedtls's mrbgem.rake (spec.cc.defines) selects mbedtls's feature
# set through this config header; an object recompiled without it disagrees
# with the rest of the archive on struct layout — silent, not a link error.
MBEDTLS_DIR = File.join(ROOT, "vendor", "picoruby", "mrbgems", "picoruby-mbedtls")
gem_defs << "MBEDTLS_CONFIG_FILE='\"#{MBEDTLS_DIR}/include/mbedtls_config.h\"'"
puts "Defines from gems (#{gem_defs.size}): #{gem_defs.join(' ')}"
DEFINES = (defs + gem_defs).map { |d| "-D#{d}" }.join(" ")

# The deployment target must match for the same reason: parse the config's
# `watchos_min = ENV["WATCHOS_MIN"] || <default>` so recompiled objects carry
# the same -mwatchos-version-min as the originals.
min_default = config_src[/watchos_min\s*=\s*ENV\["WATCHOS_MIN"\]\s*\|\|\s*"([^"]+)"/, 1]
raise "no watchos_min derivation found in #{CONFIG_RB}" unless min_default
WATCHOS_MIN = ENV["WATCHOS_MIN"] || min_default

# Mirrors the gem set a device build_config can pull in; grows when a gem
# with its own headers joins one. picoruby-ble bringing picoruby-mbedtls into
# a watchOS config for the first time is what the last two entries are for.
INCLUDES = [
  File.join("build", BUILD_NAME, "include"),
  "vendor/picoruby/include",
  "vendor/picoruby/mrbgems/picoruby-mruby/lib/mruby/include",
  "vendor/picoruby/mrbgems/picoruby-mruby/include",
  "vendor/picoruby/mrbgems/mruby-compiler/include",
  "vendor/picoruby/mrbgems/mruby-compiler/lib/prism/include",
  "vendor/picoruby/mrbgems/picoruby-mruby/lib/mruby/mrbgems/mruby-task/include",
  "vendor/picoruby/mrbgems/picoruby-mruby/lib/mruby/mrbgems/mruby-io/include",
  "vendor/picoruby/mrbgems/picoruby-machine/include",
  "vendor/picoruby/mrbgems/picoruby-machine/lib/estalloc",
  "vendor/picoruby/mrbgems/picoruby-io-console/include",
  "vendor/picoruby/mrbgems/hal-io-darwin/src",
  "vendor/picoruby/mrbgems/picoruby-mruby/lib/mruby/src",
  "vendor/picoruby/mrbgems/picoruby-mbedtls/lib/mbedtls/include",
  "vendor/picoruby/mrbgems/picoruby-mbedtls/include",
].map { |p| "-I #{File.join(ROOT, p).shellescape}" }.join(" ")

# -Wno-undef: config_adjust_ssl.h #undefs a macro that ssl.h then tests with
# a bare #if (upstream mbedtls bug, present through v3.6.7); matches the flag
# picoruby-mbedtls's mrbgem.rake adds for the same reason.
BASE_FLAGS = "-arch arm64_32 -isysroot #{SDK.shellescape} " \
             "-mwatchos-version-min=#{WATCHOS_MIN} -O2 -Wno-undef " \
             "#{DEFINES} #{INCLUDES}"

def arm64?(path)
  `lipo -info #{path.shellescape} 2>/dev/null`.match?(/: arm64$/)
end

def source_from_d(d_file)
  return nil unless File.exist?(d_file)
  content = File.read(d_file)
  # .d format: "obj.o: \ \n  source.c \ \n  header.h ..."
  # First .c or generated file after the colon
  files = content.gsub(/\\\n/, " ").split(":").last.to_s.split
  files.find { |f| f.end_with?(".c") && File.exist?(f) }
end

arm64_objs = Dir.glob(File.join(BUILD_DIR, "**", "*.o")).select { |o| arm64?(o) }
puts "#{arm64_objs.count} arm64 objects to recompile as arm64_32"

new_arm32_objs = []
failed = []

arm64_objs.each do |obj|
  d_file = obj.sub(/\.o$/, ".d")
  src = source_from_d(d_file)
  unless src
    puts "  SKIP (no source): #{File.basename(obj)}"
    next
  end

  out = obj.sub(/\.o$/, "_arm32.o")
  cmd = "#{CLANG.shellescape} #{BASE_FLAGS} -c #{src.shellescape} -o #{out.shellescape} 2>&1"
  result = `#{cmd}`
  if $?.success?
    new_arm32_objs << out
    print "."
    $stdout.flush
  else
    failed << [src, result]
    print "F"
    $stdout.flush
  end
end

puts "\n#{new_arm32_objs.count} compiled OK, #{failed.count} failed"
failed.each { |src, err| puts "  FAIL: #{src}\n    #{err.lines.first.to_s.strip}" }

unless failed.empty?
  abort "\n#{failed.count} source(s) failed to recompile for arm64_32. " \
        "Refusing to archive a partial libmruby.a — the staged library would be " \
        "missing these objects. INCLUDES and gem_defs must mirror the flags the gems " \
        "add to the real build; a newly added gem is the usual cause."
end

# Combine with existing arm64_32 objects
existing_arm32 = Dir.glob(File.join(BUILD_DIR, "**", "*.o")).select do |o|
  !o.end_with?("_arm32.o") && `lipo -info #{o.shellescape} 2>/dev/null`.match?(/: arm64_32$/)
end

all_objs = (existing_arm32 + new_arm32_objs).uniq
puts "Archiving #{all_objs.count} arm64_32 objects..."

lib_out = File.join(BUILD_DIR, "lib", "libmruby.a")
`cp #{lib_out.shellescape} #{(lib_out + ".bak").shellescape}` if File.exist?(lib_out)
# Must remove the fat file before ar can create a fresh arm64_32-only archive
File.delete(lib_out) if File.exist?(lib_out)
`#{AR.shellescape} -rcs #{lib_out.shellescape} #{all_objs.map(&:shellescape).join(" ")}`
puts "Created: #{lib_out}"
puts `lipo -info #{lib_out.shellescape}`.strip
