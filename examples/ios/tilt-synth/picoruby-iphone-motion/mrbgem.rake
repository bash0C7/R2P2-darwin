MRuby::Gem::Specification.new('picoruby-iphone-motion') do |spec|
  spec.license = 'MIT'
  spec.author  = 'bash0C7'
  spec.summary = 'Read iPhone Device Motion (attitude pitch/roll) from Ruby'
  # No add_dependency: the Darwin port references only its own Swift backend
  # (pmotion_*), resolved at app link time. No mbedtls/cyw43/rp2040 transitive
  # deps, same rationale as picoruby-iphone-torch.
end
