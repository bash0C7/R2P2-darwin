# macOS (Darwin) host-native build & run: the macos: namespace. Uses the main
# Rakefile's ROOT / PICORUBY_SRC / BUILD_DIR constants and its `setup` task.

# Brew openssl@3 prefix on LDFLAGS/CFLAGS so the networking gembox can find
# ssl/crypto. Inert if openssl@3 isn't brew-installed.
def macos_build_env
  env = { "MRUBY_BUILD_DIR" => BUILD_DIR }
  ssl = `brew --prefix openssl@3 2>/dev/null`.strip
  unless ssl.empty?
    env["LDFLAGS"] = [ENV["LDFLAGS"], "-L#{ssl}/lib"].compact.join(" ")
    env["CFLAGS"]  = [ENV["CFLAGS"],  "-I#{ssl}/include"].compact.join(" ")
  end
  cfg = ENV["MRUBY_CONFIG"] || File.join(ROOT, "build_config", "r2p2-picoruby-darwin.rb")
  env["MRUBY_CONFIG"] = File.absolute_path(cfg)
  env
end

namespace :macos do
  desc "Verify macOS host prerequisites (Xcode CLT, brew openssl@3, Swift)"
  task :check do
    ok = true
    if system("xcode-select", "-p", out: File::NULL, err: File::NULL)
      puts "Xcode CLT:  ok"
    else
      warn "Xcode CLT:  missing — run `xcode-select --install`"
      ok = false
    end
    ssl = `brew --prefix openssl@3 2>/dev/null`.strip
    if ssl.empty?
      warn "openssl@3:  missing — run `brew install openssl@3` (networking gem links ssl/crypto)"
      ok = false
    else
      puts "openssl@3:  #{ssl}"
    end
    swift = `swift --version 2>/dev/null`.lines.first&.strip
    if swift.nil? || swift.empty?
      warn "Swift:      missing — install Xcode (needed for the picoruby-ble Darwin port)"
    else
      puts "Swift:      #{swift}"
    end
    abort "missing prerequisites" unless ok
  end

  desc "Host-native build of the fetched picoruby tree into ./build"
  task build: :setup do
    sh macos_build_env, "cd #{PICORUBY_SRC.shellescape} && rake"
  end

  desc "Run the r2p2 shell, or APP=path/to.rb on the picoruby runner"
  task :run do
    r2p2 = File.join(BUILD_DIR, "host", "bin", "r2p2")
    pr   = File.join(BUILD_DIR, "host", "bin", "picoruby")
    if (app = ENV["APP"])
      raise "Not built. Run `rake macos:build` first." unless File.executable?(pr)
      exec({}, pr, app)
    elsif File.executable?(r2p2)
      exec({}, r2p2)
    else
      raise "Not built (or this build has no r2p2 shell — try APP=path/to.rb)."
    end
  end

  desc "Build a single binary embedding APP=path/to/app.rb (NAME defaults to APP basename)"
  task single: :setup do
    app = ENV["APP"] or abort "APP=path/to/app.rb is required"
    abort "APP not found: #{app}" unless File.file?(app)
    name = (ENV["NAME"] || File.basename(app, ".rb")).downcase
    abort "NAME must match /\\A[a-z][a-z0-9_-]*\\z/ (got: #{name.inspect})" unless name =~ /\A[a-z][a-z0-9_-]*\z/

    staging = File.join(ROOT, "tmp", "single")
    gem_dir = File.join(staging, "picoruby-bin-#{name}")
    rm_rf staging
    mkdir_p File.join(gem_dir, "mrblib")
    mkdir_p File.join(gem_dir, "tools", name)

    File.write(File.join(gem_dir, "mrbgem.rake"), <<~MRBGEM)
      MRuby::Gem::Specification.new('picoruby-bin-#{name}') do |spec|
        spec.license = 'MIT'
        spec.author  = ''
        spec.summary = 'PicoRuby single-binary built by rake macos:single'

        spec.add_dependency 'picoruby-mruby'

        bin_name = '#{name}'
        build.bins << bin_name

        main_src = "\#{spec.dir}/tools/\#{bin_name}/\#{bin_name}.c"
        bin_obj  = objfile(main_src.pathmap("\#{build_dir}/tools/\#{bin_name}/%n"))

        file bin_obj => [main_src] do |t|
          build.cc.run t.name, main_src
        end

        file exefile("\#{build.build_dir}/bin/\#{bin_name}") => [bin_obj, build.libmruby_static] do |f|
          build.linker.run f.name, f.prerequisites
        end
      end
    MRBGEM

    cp app, File.join(gem_dir, "mrblib", "app.rb")

    File.write(File.join(gem_dir, "tools", name, "#{name}.c"), <<~C_MAIN)
      #include <stdio.h>
      #include <stdint.h>

      #if !defined(PICORB_PLATFORM_POSIX)
      #define PICORB_PLATFORM_POSIX 1
      #endif

      #include "picoruby.h"

      #ifndef HEAP_SIZE
      #define HEAP_SIZE (1024 * 2000)
      #endif

      static uint8_t vm_heap[HEAP_SIZE] __attribute__((aligned(16)));

      /* Defined in mruby-compiler (ccontext.c). */
      extern mrb_state *global_mrb;

      int main(int argc, char **argv) {
        (void)argc;
        mrb_state *vm = NULL;
        picorb_vm_init();
        mrb_close(vm);
        return 0;
      }
    C_MAIN

    single_cfg = File.join(ROOT, "build_config", "r2p2-picoruby-darwin-single.rb")
    env = macos_build_env.merge(
      "MRUBY_CONFIG"         => File.absolute_path(single_cfg),
      "R2P2_SINGLE_GEM_PATH" => gem_dir,
    )
    sh env, "cd #{PICORUBY_SRC.shellescape} && rake"

    puts ""
    puts "Single binary built: #{File.join(BUILD_DIR, "host", "bin", name)}"
  end
end
