# Mapping-logic verification for TiltSynth's bundled Ruby (quantize/clamp).
# Runs under host CRuby (`ruby test_mapping.rb`): TiltSynthApp uses only plain
# Ruby for its mapping math (no PicoRuby-specific gems), so CRuby and the
# reduced PicoRuby VM produce identical results. Stubs Motion/Synth (normally
# provided by the picoruby-iphone-motion/-synth gems) so this runs with no
# device, no build, and no Xcode. Mirrors stackchan's test_frames.rb pattern.

class Motion
  def initialize
    @available = true
    @pitch = 0.0
    @roll = 0.0
  end
  attr_accessor :pitch, :roll
  def available=(v); @available = v; end
  def available?; @available; end
end

class Synth
  attr_reader :note, :fm_depth
  def start; end
  def stop; end
  def note=(v); @note = v; end
  def fm_depth=(v); @fm_depth = v; end
  def reset!; @note = nil; @fm_depth = nil; end
end

require_relative "app"

$failures = 0
def expect(label, actual, want)
  if actual == want
    puts "PASS #{label}: #{actual.inspect}"
  else
    $failures += 1
    puts "FAIL #{label}: got #{actual.inspect} want #{want.inspect}"
  end
end

def tick_with(pitch:, roll:, available: true)
  $app.motion.pitch = pitch
  $app.motion.roll = roll
  $app.motion.available = available
  $app.tick
end

tick_with(pitch: -30.0, roll: 0.0)
expect("pitch -30 -> lowest note", $app.synth.note, 261.6)

tick_with(pitch: 30.0, roll: 0.0)
expect("pitch +30 -> highest note", $app.synth.note, 880.0)

tick_with(pitch: -100.0, roll: 0.0)
expect("pitch below range clamps to lowest note", $app.synth.note, 261.6)

tick_with(pitch: 100.0, roll: 0.0)
expect("pitch above range clamps to highest note", $app.synth.note, 880.0)

tick_with(pitch: 0.0, roll: -45.0)
expect("roll -45 -> fm_depth 0.0", $app.synth.fm_depth, 0.0)

tick_with(pitch: 0.0, roll: 45.0)
expect("roll +45 -> fm_depth 1.0", $app.synth.fm_depth, 1.0)

tick_with(pitch: 0.0, roll: -200.0)
expect("roll below range clamps to 0.0", $app.synth.fm_depth, 0.0)

tick_with(pitch: 0.0, roll: 200.0)
expect("roll above range clamps to 1.0", $app.synth.fm_depth, 1.0)

$app.synth.reset!
tick_with(pitch: 30.0, roll: 0.0, available: false)
expect("unavailable motion -> tick is a no-op", $app.synth.note, nil)

if $failures.zero?
  puts "\nall passed"
else
  puts "\n#{$failures} FAILED"
  exit 1
end
