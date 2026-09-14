# rakelib/aot.rake — keeps every spinel/suppify-compiled AOT kernel
# (examples/ios/*/aot-kernel/*.rb) working against the pinned spinel/suppify
# commits recorded in .github/aot-pins.yml, and lets that pin be advanced
# deliberately once a candidate pair is verified to still work.
#
# spinel and suppify are external tools (never vendored): both are cloned
# ephemerally into build/aot, the same way `cc` is discovered on PATH rather
# than checked in. The generated picoruby-<kernel>/ gem in each example dir
# is a reproducible build product (gitignored), not committed — regenerate
# it from source rather than hand-editing it.
require "yaml"
require "fileutils"
require "open3"

AOT_PINS_FILE = File.join(ROOT, ".github", "aot-pins.yml")
AOT_SCRATCH   = File.join(BUILD_DIR, "aot")

def aot_pins
  YAML.load_file(AOT_PINS_FILE)
end

# Every AOT kernel in the tree: examples/ios/<example>/aot-kernel/<kernel>.rb
# paired with a same-named .rbs sidecar, generating a sibling
# examples/ios/<example>/picoruby-<kernel>/ mrbgem.
def aot_kernels
  Dir.glob(File.join(ROOT, "examples", "ios", "*", "aot-kernel", "*.rb")).map do |rb|
    example = File.basename(File.dirname(File.dirname(rb)))
    kernel  = File.basename(rb, ".rb")
    { example: example, kernel: kernel, dir: File.dirname(rb) }
  end
end

def aot_git_head(dir)
  return nil unless Dir.exist?(dir)
  out, status = Open3.capture2("git", "-C", dir, "rev-parse", "HEAD")
  status.success? ? out.strip : nil
end

def aot_build_spinel(dest, ref)
  return if aot_git_head(dest) == ref
  FileUtils.rm_rf(dest)
  sh "git", "clone", "--quiet", "https://github.com/matz/spinel.git", dest
  sh "git", "-C", dest, "checkout", "--quiet", ref
  sh "make", "-C", dest, "deps"
  sh "make", "-C", dest
end

def aot_checkout_suppify(dest, ref)
  return if aot_git_head(dest) == ref
  FileUtils.rm_rf(dest)
  sh "git", "clone", "--quiet", "https://github.com/bash0C7/suppify.git", dest
  sh "git", "-C", dest, "checkout", "--quiet", ref
end

def aot_regen_kernel(k, spinel_dir, suppify_dir)
  gem_dir = File.join(File.dirname(k[:dir]), "picoruby-#{k[:kernel]}")
  FileUtils.rm_rf(gem_dir)
  env = {
    "SPINEL"     => File.join(spinel_dir, "bin", "spinel"),
    "SPINEL_LIB" => File.join(spinel_dir, "lib"),
  }
  sh env, "ruby", "-I", File.join(suppify_dir, "lib"), File.join(suppify_dir, "suppify.rb"),
     "#{k[:kernel]}.rb", "-o", k[:kernel], "-t", "picoruby", "-d", "..", chdir: k[:dir]
end

namespace :aot do
  desc "Print the pinned spinel/suppify commits (.github/aot-pins.yml)"
  task :pins do
    p = aot_pins
    puts "spinel:  #{p['spinel']}"
    puts "suppify: #{p['suppify']}"
  end

  desc "Clone+build spinel and suppify under build/aot (env SPINEL_REF/SUPPIFY_REF override the pin file; skips work already at that commit)"
  task :setup do
    p = aot_pins
    aot_build_spinel(File.join(AOT_SCRATCH, "spinel"), ENV["SPINEL_REF"] || p["spinel"])
    aot_checkout_suppify(File.join(AOT_SCRATCH, "suppify"), ENV["SUPPIFY_REF"] || p["suppify"])
  end

  desc "Regenerate every AOT kernel gem from build/aot's spinel+suppify"
  task regen: :setup do
    spinel_dir  = File.join(AOT_SCRATCH, "spinel")
    suppify_dir = File.join(AOT_SCRATCH, "suppify")
    aot_kernels.each { |k| aot_regen_kernel(k, spinel_dir, suppify_dir) }
  end

  desc "Regenerate every kernel, then Simulator-build every example that has one — the deterministic 'does the pin still work' check"
  task refresh: :regen do
    aot_kernels.map { |k| k[:example] }.uniq.each do |example|
      %w[lib gen build].each { |step| Rake::Task["ios:#{example}:#{step}"].invoke }
    end
  end

  desc "Try candidate spinel/suppify refs; adopt into .github/aot-pins.yml only if aot:refresh passes"
  task :bump_pins, [:spinel_ref, :suppify_ref] do |_t, args|
    raise "usage: rake aot:bump_pins[<spinel_ref>,<suppify_ref>]" unless args[:spinel_ref] && args[:suppify_ref]

    ENV["SPINEL_REF"]  = args[:spinel_ref]
    ENV["SUPPIFY_REF"] = args[:suppify_ref]
    %w[setup regen refresh].each { |t| Rake::Task["aot:#{t}"].reenable }
    aot_kernels.map { |k| k[:example] }.uniq.each do |example|
      %w[lib gen build].each { |step| Rake::Task["ios:#{example}:#{step}"].reenable }
    end
    Rake::Task["aot:refresh"].invoke

    File.write(AOT_PINS_FILE, <<~YAML)
      # Single source of truth for the spinel/suppify commits this repo's AOT
      # kernels (examples/ios/*/aot-kernel/) are verified against. Read by
      # `rake aot:*` (Rakefile / rakelib/aot.rake) and by .github/workflows/ci.yml —
      # never hardcode either ref anywhere else.
      spinel: #{args[:spinel_ref]}
      suppify: #{args[:suppify_ref]}
    YAML
    puts "adopted spinel=#{args[:spinel_ref]} suppify=#{args[:suppify_ref]} -- review and commit .github/aot-pins.yml"
  end
end
