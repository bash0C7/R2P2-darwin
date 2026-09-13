MRuby::Gem::Specification.new('picoruby-gpu_bench') do |spec|
  spec.license = 'MIT'
  spec.author  = 'bash0C7'
  spec.summary = 'Run the repl example bench_tick kernel on the GPU (Metal) for A/B comparison'
  # Require-free, like the suppify-generated picoruby-bench_tick gem this
  # compares against: Kernel.gpu_bench_tick registers on kernel_module at
  # mrb_open. No Ruby half, so no require_name.
end
