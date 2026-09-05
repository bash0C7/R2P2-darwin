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

# Subtitle / audio codec (speak feature).
expect("encode_text plain", FrameCodec.encode_text("こんにちは"), "<text:こんにちは>\n")
# Frame delimiters are widened; CR/LF become a single space.
expect("encode_text sanitize", FrameCodec.encode_text("a,b<c>d\ne"), "<text:a、b＜c＞d e>\n")
# A CR/LF run (not just a lone CR or LF) collapses to a single space.
expect("encode_text CRLF collapse", FrameCodec.encode_text("a\r\nb"), "<text:a b>\n")
# 19-char cap (multibyte-safe), mirroring the device's SUBTITLE_MAX_CHARS.
expect("encode_text truncate", FrameCodec.encode_text("あ" * 25),
       "<text:" + "あ" * 19 + ">\n")
expect("encode_audio_header", FrameCodec.encode_audio_header(1234), "<A:1234>\n")

# chunk_audio_hex slices in hex space (ASCII) and packs per chunk, so binary
# mu-law never meets char-based String#[] (MRB_UTF8_STRING VM).
hex = "00112233" * 100   # 400 bytes of audio
chunks = FrameCodec.chunk_audio_hex(hex)
expect("chunk count", chunks.length, 3)
expect("chunk sizes", chunks.map { |c| c.bytesize }, [180, 180, 40])
expect("chunk head bytes", chunks[0][0, 4].bytes, [0x00, 0x11, 0x22, 0x33])

$app.subtitle("やあ,ねえ")
expect("subtitle frame", last_frame, "<text:やあ、ねえ>\n")

# Not connected (BleLink stub): speak_audio must write NOTHING (an orphan
# <A:N> header would trap the device in an audio drain window later).
sent_before = $app.ble.sent.length
$app.speak_audio("00112233")
expect("speak_audio not connected writes nothing",
       $app.ble.sent.length, sent_before)

# Connected happy path: header byte count matches N, header precedes chunks,
# chunk count/order is fixed. A recording stub whose connected? is always
# true (BleLink's is hardwired false, so we can't drive this through $app).
class ConnectedBleStub
  attr_reader :sent

  def initialize
    @sent = []
  end

  def connected?
    true
  end

  def write(frame)
    @sent << frame
    :ok
  end

  def write_chunk(data)
    @sent << data
    :ok
  end
end

# app.rb's msleep is a top-level method; redefining it here (same top-level
# binding via require_relative) overrides it so this test doesn't sleep for
# real pacing/drain delays.
def msleep(ms)
end

connected_app = Stackchan.new(ConnectedBleStub.new)
audio_hex = "00112233" * 100   # 400 bytes of audio
connected_app.speak_audio(audio_hex)
stub_sent = connected_app.ble.sent
expect("speak_audio header byte count", stub_sent[0], "<A:400>\n")
expect("speak_audio chunk sizes, header-then-chunks order",
       stub_sent[1..3].map { |c| c.bytesize }, [180, 180, 40])
expect("speak_audio frame count (header + 3 chunks)", stub_sent.length, 4)

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
