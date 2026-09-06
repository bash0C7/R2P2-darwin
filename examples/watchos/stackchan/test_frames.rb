# Frame-encoding verification for the Stack-chan watch controller's bundled Ruby.
# Runs under host CRuby (`ruby test_frames.rb`): the encoders build plain
# strings, so CRuby and the reduced PicoRuby VM produce identical frames. This
# guards the wire format against regressions without a watch or a build.
#
# It loads app.rb (whose BleLink records frames instead of touching a radio) and
# asserts the exact bytes the firmware expects. Frame formats mirror the PC CLI's
# verified codec (stackchan-picoruby/pc/stackchan/test/test_ble_*.rb) and the iOS
# example's test_frames.rb.

require_relative "app"

# head_sweep paces its frames with msleep, which app.rb defines at top level.
# require_relative shares that top-level binding, so redefining msleep HERE
# (after the require, or app.rb's definition would win) makes head_sweep run
# instantly instead of sleeping 1.8 s.
def msleep(ms)
end

$failures = 0

def expect(label, actual, want)
  if actual == want
    puts "PASS #{label}: #{actual.inspect}"
  else
    $failures += 1
    puts "FAIL #{label}: got #{actual.inspect} want #{want.inspect}"
  end
end

def expect_include(label, actual, allowed)
  if allowed.include?(actual)
    puts "PASS #{label}: #{actual.inspect}"
  else
    $failures += 1
    puts "FAIL #{label}: got #{actual.inspect}, not one of #{allowed.inspect}"
  end
end

# Drive the dispatcher and read back what BleLink recorded.
def last_frame
  $app.ble.sent.last
end

# ---- face_toggle: smile <-> joy ------------------------------------------
# FACE_INDICES: smile => "1", joy => "2". The app boots holding "smile", so the
# FIRST toggle flips to joy.
$app.face_toggle
expect("face_toggle 1st -> joy", last_frame, "<F:2>\n")
$app.face_toggle
expect("face_toggle 2nd -> smile", last_frame, "<F:1>\n")
$app.face_toggle
expect("face_toggle 3rd -> joy", last_frame, "<F:2>\n")
$app.face_toggle
expect("face_toggle 4th -> smile", last_frame, "<F:1>\n")

# ---- led_show: six colours in a random order, then off -------------------
# Every acceptable "on" frame, one per random colour.
on_frames = Stackchan::LED_RANDOM_COLORS.map do |c|
  rgb = FrameCodec::LED_COLORS[c]
  "<L:1,R:#{rgb[0]},G:#{rgb[1]},B:#{rgb[2]},S:B,M:b>\n"
end

OFF_FRAME = "<L:1,R:0,G:0,B:0,S:B,M:o>\n"

# One tap runs the whole show: six blink frames, one per colour, then the off
# frame. Capture a run's frames by slicing what BleLink recorded.
def led_show_frames
  before = $app.ble.sent.length
  $app.led_show
  $app.ble.sent[before..-1]
end

run = led_show_frames
expect("led_show emits 6 colours + off", run.length, 7)
expect("led_show ends by switching the LED off", run[-1], OFF_FRAME)

# Each of the six is a legal blink frame, and every colour appears exactly once —
# that is what "cycles through all six" means, and a `rand` that repeats a colour
# would fail here even though each individual frame is legal.
illegal = run[0, 6] - on_frames
if illegal.empty?
  puts "PASS led_show blink frames are all legal: 6 checked"
else
  $failures += 1
  puts "FAIL led_show blink frames include illegal frame(s): #{illegal.inspect}"
end
expect("led_show uses each colour exactly once", run[0, 6].uniq.length, 6)

# The order must actually be randomised. Comparing just two runs would flag a
# 1-in-720 coincidence as a failure, so take several and require that they are
# not all identical.
orders = 5.times.map { led_show_frames[0, 6] }
if orders.uniq.length >= 2
  puts "PASS led_show order varies: #{orders.uniq.length} distinct orders over 5 runs"
else
  $failures += 1
  puts "FAIL led_show order never varied over 5 runs: #{orders.first.inspect}"
end

# ---- head_sweep: left -> right -> up -> neutral --------------------------
before = $app.ble.sent.length
$app.head_sweep
swept = $app.ble.sent[before..-1]
expect("head_sweep emits 4 frames", swept.length, 4)
# "left" (StackChan's own perspective) is YL on the wire; "right" is YR.
expect("head_sweep 1 left",    swept[0], "<YL:60,T:500>\n")
expect("head_sweep 2 right",   swept[1], "<YR:60,T:500>\n")
expect("head_sweep 3 up",      swept[2], "<PU:40,T:500>\n")
expect("head_sweep 4 neutral", swept[3], "<YL:0,PU:0,T:400>\n")

# ---- the encoders themselves --------------------------------------------
expect("encode_face neutral", FrameCodec.encode_face("neutral"), "<F:0>\n")
expect("encode_face smile",   FrameCodec.encode_face("smile"),   "<F:1>\n")
expect("encode_face joy",     FrameCodec.encode_face("joy"),     "<F:2>\n")

expect("encode_led red solid both",
       FrameCodec.encode_led(color: "red", side: "both", mode: "solid"),
       "<L:1,R:255,G:0,B:0,S:B,M:s>\n")
# "left" (StackChan perspective) reverses to "R" on the wire; do not "fix" this.
expect("encode_led green blink left",
       FrameCodec.encode_led(color: "green", side: "left", mode: "blink"),
       "<L:1,R:0,G:255,B:0,S:R,M:b>\n")
expect("encode_led right reverses to L",
       FrameCodec.encode_led(color: "blue", side: "right", mode: "solid"),
       "<L:1,R:0,G:0,B:255,S:L,M:s>\n")

expect("encode_head left 50 500ms",
       FrameCodec.encode_head(yaw_left: 50, time_ms: 500), "<YL:50,T:500>\n")
expect("encode_head right 30 no-time",
       FrameCodec.encode_head(yaw_right: 30), "<YR:30>\n")
expect("encode_head up 20 250ms",
       FrameCodec.encode_head(pitch_up: 20, time_ms: 250), "<PU:20,T:250>\n")

expect("parse_ack ok",    FrameCodec.parse_ack("."), :ok)
expect("parse_ack error", FrameCodec.parse_ack("?"), :error)

# ---- the subset really is a subset --------------------------------------
# speak / torque / touch are out of scope for the watch. Their helpers must be
# gone, not merely unused, so the watch VM never carries dead weight.
%w[encode_text encode_audio_header chunk_audio_hex sanitize_text
   truncate_chars encode_torque parse_touch].each do |gone|
  if FrameCodec.respond_to?(gone)
    $failures += 1
    puts "FAIL FrameCodec.#{gone} should not exist in the watch subset"
  else
    puts "PASS FrameCodec.#{gone} absent"
  end
end
%w[face led head torque subtitle speak_audio led_toggle].each do |gone|
  if $app.respond_to?(gone)
    $failures += 1
    puts "FAIL Stackchan##{gone} should not exist in the watch subset"
  else
    puts "PASS Stackchan##{gone} absent"
  end
end

if $failures.zero?
  puts "\nall passed"
else
  puts "\n#{$failures} FAILED"
  exit 1
end
