MRuby::Gem::Specification.new('picoruby-bench_tick') do |spec|
  spec.version = "0.1.0"
  spec.author  = 'suppify'
  spec.summary = 'suppify-generated native gem'
  spec.license = "MIT"

  # Public neutral header for firmware/consumer code.
  spec.cc.include_paths << "#{dir}/include"
  # libm for the spinel runtime's math (harmless where libm is in libc).
  spec.linker.libraries << 'm'
  # Namespaces every vendored spinel runtime symbol to this library
  # (so a second suppify mrbgem linked into the same firmware image
  # doesn't collide with this one's runtime state) and silences the
  # bundled runtime's own harmless warnings. See Suppify::SymbolPrefix.
  spec.cc.flags << "-include #{dir}/src/bench_tick_prelude.h"
end
