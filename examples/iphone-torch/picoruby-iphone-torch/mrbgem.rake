MRuby::Gem::Specification.new('picoruby-iphone-torch') do |spec|
  spec.license = 'MIT'
  spec.author  = 'bash0C7'
  spec.summary = 'Control the iPhone camera torch (flashlight) from Ruby'
  # No add_dependency: the Darwin port references only its own Swift backend
  # (ptorch_*), resolved at app link time. No mbedtls/cyw43/rp2040 transitive deps.
end
