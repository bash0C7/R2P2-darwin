# Frame-encoding verification for the Stack-chan controller's bundled Ruby.
# Runs under host CRuby (`ruby test_frames.rb`): the encoders build plain
# strings, so CRuby and the reduced PicoRuby VM produce identical frames. This
# guards the wire format against regressions without a device or a build.
#
# It loads app.rb (whose BleLink records frames instead of touching a radio) and
# asserts the exact bytes the firmware expects. Frame formats mirror the PC CLI's
# verified codec (stackchan-picoruby/pc/stackchan/test/test_ble_*.rb).

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

# Drive the dispatcher and capture the last frame BleLink recorded.
def last_frame
  $app.ble.sent.last
end

$app.face("joy")
expect("face joy", last_frame, "<F:2>\n")

$app.face("neutral")
expect("face neutral", last_frame, "<F:0>\n")

$app.led("red")
expect("led red default", last_frame, "<L:1,R:255,G:0,B:0,S:B,M:s>\n")

$app.led("green:blink:left")
# "left" (StackChan perspective) reverses to "R" on the wire.
expect("led green blink left", last_frame, "<L:1,R:0,G:255,B:0,S:R,M:b>\n")

$app.head("left:50:500")
expect("head left 50 500ms", last_frame, "<YL:50,T:500>\n")

$app.head("right:30")
expect("head right 30 no-time", last_frame, "<YR:30>\n")

$app.head("up:20:250")
expect("head up 20 250ms", last_frame, "<PU:20,T:250>\n")

$app.torque("on")
expect("torque on", last_frame, "<torque:on>\n")

$app.torque("off")
expect("torque off", last_frame, "<torque:off>\n")

# Parse helpers.
expect("parse_ack ok", FrameCodec.parse_ack("."), :ok)
expect("parse_ack error", FrameCodec.parse_ack("?"), :error)
expect("parse_touch zone 2", FrameCodec.parse_touch("<touch:2>\n"), 2)
expect("parse_touch non-touch", FrameCodec.parse_touch("<F:1>\n"), nil)

if $failures.zero?
  puts "\nall passed"
else
  puts "\n#{$failures} FAILED"
  exit 1
end
