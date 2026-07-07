MRuby::Gem::Specification.new('picoruby-iphone-synth') do |spec|
  spec.license = 'MIT'
  spec.author  = 'bash0C7'
  spec.summary = 'Drive a sine+FM oscillator (AVAudioEngine) from Ruby'
  # No add_dependency: the Darwin port references only its own Swift backend
  # (psynth_*), resolved at app link time.
end
