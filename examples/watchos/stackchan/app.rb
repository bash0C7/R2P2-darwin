# Stack-chan watch controller — the bundled, fixed Ruby that the persistent
# PicoRuby VM runs on watchOS. It is not user-editable and not downloaded:
# PicoRuby is simply the implementation language for the app's own behavior
# (Guideline 2.5.2-free).
#
# A subset of examples/ios/stackchan/app.rb: three controls (a happy-face
# toggle, a random-colour LED blink toggle, and a one-shot head sweep back to
# neutral). Speak (subtitle + mu-law audio), torque, and touch events are out of
# scope for the watch.
#
# The frame encoders mirror the PC CLI's codec
# (stackchan-picoruby/pc/stackchan/lib/stackchan/ble/{frame_codec,face_table,
# led_color_table}.rb), with two differences for the reduced PicoRuby VM and the
# Swift->VM call seam:
#   1. No require_relative / module namespacing — the bundled app is one source.
#   2. String keys (not Symbols) because vm_call delivers a single String arg
#      from the Swift UI. The emitted frames are byte-identical to the PC codec.
#
# The wire frame format and the left/right reversal match the hardware and are
# load-bearing; do not "fix" SIDE_TO_CHAR.

module FrameCodec
  # API "left"/"right" are StackChan's own perspective (its hands); the firmware
  # wires them reversed, so "left" -> "R" and "right" -> "L" on the wire.
  SIDE_TO_CHAR = { "left" => "R", "right" => "L", "both" => "B" }
  MODE_TO_CHAR = { "solid" => "s", "blink" => "b", "breathing" => "p", "off" => "o" }
  FACE_INDICES = {
    "neutral" => "0", "smile" => "1", "joy" => "2",
    "surprised" => "3", "sad" => "4", "angry" => "5",
  }
  LED_COLORS = {
    "red" => [255, 0, 0], "green" => [0, 255, 0], "blue" => [0, 0, 255],
    "yellow" => [255, 255, 0], "cyan" => [0, 255, 255], "magenta" => [255, 0, 255],
    "white" => [255, 255, 255], "off" => [0, 0, 0],
  }

  ACK_OK    = "."
  ACK_ERROR = "?"

  def self.encode_pairs(pairs)
    "<" + pairs.map { |k, v| "#{k}:#{v}" }.join(",") + ">\n"
  end

  def self.encode_face(name)
    index = FACE_INDICES[name]
    raise ArgumentError, "unknown face: #{name}" unless index
    encode_pairs({ "F" => index })
  end

  # color: a named color string ("red"...). side: "left"/"right"/"both".
  # mode: "solid"/"blink"/"breathing"/"off".
  def self.encode_led(color:, side:, mode:)
    rgb = LED_COLORS[color]
    raise ArgumentError, "unknown color: #{color}" unless rgb
    side_char = SIDE_TO_CHAR[side]
    raise ArgumentError, "unknown side: #{side}" unless side_char
    mode_char = MODE_TO_CHAR[mode]
    raise ArgumentError, "unknown mode: #{mode}" unless mode_char
    encode_pairs({
      "L" => "1", "R" => rgb[0].to_s, "G" => rgb[1].to_s, "B" => rgb[2].to_s,
      "S" => side_char, "M" => mode_char,
    })
  end

  # Exactly one of yaw_left/yaw_right may be set (0..100); pitch_up optional
  # (0..100); time_ms optional. nil means "omit".
  def self.encode_head(yaw_left: nil, yaw_right: nil, pitch_up: nil, time_ms: nil)
    if !yaw_left.nil? && !yaw_right.nil?
      raise ArgumentError, "yaw_left and yaw_right are mutually exclusive"
    end
    if yaw_left.nil? && yaw_right.nil? && pitch_up.nil?
      raise ArgumentError, "encode_head needs one of yaw_left/yaw_right/pitch_up"
    end
    pairs = {}
    pairs["YL"] = yaw_left.to_s  unless yaw_left.nil?
    pairs["YR"] = yaw_right.to_s unless yaw_right.nil?
    pairs["PU"] = pitch_up.to_s  unless pitch_up.nil?
    pairs["T"]  = time_ms.to_s   if time_ms
    encode_pairs(pairs)
  end

  # frame[0,1] is safe on a bare 1-char ACK byte too.
  def self.parse_ack(frame)
    case frame[0, 1]
    when ACK_OK    then :ok
    when ACK_ERROR then :error
    else raise ArgumentError, "unknown ack frame: #{frame}"
    end
  end
end

# The BLE transport seam.
#
# `RealBleLink` (below) drives picoruby-ble's central role over the Darwin
# (CoreBluetooth) port: it scans for a Stack-chan advertising the Nordic UART
# Service (NUS), connects, discovers the RX characteristic value handle, and
# writes each ASCII frame to it. picoruby-ble is only present in the on-watch /
# Simulator VM, so this file guards every reference behind `BLE_AVAILABLE`:
# under host CRuby (test_frames.rb) BLE is absent and the recording `BleLink`
# stub is used instead, keeping the frame encoders verifiable without a radio.

# The Nordic UART Service and its RX (write) characteristic, the Stack-chan
# firmware's command channel.
NUS_SERVICE_UUID = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
NUS_RX_CHAR_UUID = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
# The discovered service/characteristic :uuid128 fields are 16 big-endian bytes
# (textual UUID order). bind_rx renders them to hex and matches against these
# dash-stripped constants (avoids calling BLE::Utils.uuid).
NUS_SERVICE_UUID128_HEX = "6e400001b5a3f393e0a9e50e24dcca9e"
NUS_RX_CHAR_UUID128_HEX = "6e400002b5a3f393e0a9e50e24dcca9e"
HEX_DIGITS = "0123456789abcdef"
# Substring matched against the advertised local name to pick the robot.
STACKCHAN_NAME = "StackChan"

# watchOS suspends an app aggressively when the wrist drops, and the scan blocks
# the VM thread for its whole duration. Ten seconds is short enough to survive a
# glance and long enough to find a robot that is already advertising; the UI
# makes re-tapping Connect cheap.
SCAN_TIMEOUT_MS = 10000

# picoruby-ble's Ruby layer (BLE#initialize(role), scan, connect, ...) is a
# picogem: the C part defines the BLE constant at boot, the Ruby part loads on
# require (picoruby-require, pulled in by picoruby-machine). Host CRuby has no
# such gem, so LoadError means "no BLE here" and the stub below takes over.
begin
  require "ble"
rescue LoadError
  # host CRuby / a VM without picoruby-ble: BLE_AVAILABLE resolves below
end

# Is the picoruby-ble `BLE` class linked into this VM? The reduced PicoRuby VM
# (prism compiler) does not implement the `defined?` keyword — it compiles
# `defined?(BLE)` as a method call that raises at boot — so probe for the
# constant by referencing it and rescuing the NameError. True in the on-watch /
# Simulator VM (picoruby-ble linked); false under host CRuby (test_frames.rb),
# which then falls back to the recording `BleLink` stub.
BLE_AVAILABLE =
  begin
    BLE
    true
  rescue NameError
    false
  end

# sleep_ms comes from picoruby-machine in the watch VM; host CRuby has only
# sleep. Probe by calling (the reduced VM lacks the defined? keyword).
HAS_SLEEP_MS =
  begin
    sleep_ms(0)
    true
  rescue NameError, NoMethodError
    false
  end

def msleep(ms)
  if HAS_SLEEP_MS
    sleep_ms(ms)
  else
    sleep(ms / 1000.0)
  end
end

# Recording stub: used under host CRuby (no BLE) and as a graceful fallback so
# frames sent before a connection are not lost. Records and echoes frames.
class BleLink
  attr_reader :sent

  def initialize
    @sent = []
  end

  def connected?
    false
  end

  def connect
    print "(no BLE in this VM; frames are recorded)\n"
    false
  end

  def tick
    nil
  end

  def write(frame)
    @sent << frame
    # Echo so vm_call's stdout capture surfaces the frame during bring-up.
    print frame
    :ok
  end
end

if BLE_AVAILABLE
  # The picoruby-ble central. It overrides advertising_report_callback to connect
  # to the first peripheral whose advertised name contains STACKCHAN_NAME; after
  # connect the base class auto-discovers services/characteristics, leaving
  # @services populated and @state == :TC_IDLE.
  class StackchanCentral < BLE
    attr_reader :target

    def initialize
      super(:central)
      @target = nil
    end

    def advertising_report_callback(adv_report)
      return if @target
      if adv_report.name_include?(STACKCHAN_NAME)
        @target = adv_report
        print "Found Stack-chan; connecting\n"
        connect(adv_report)
      end
    end

    def conn_handle
      @conn_handle
    end
  end

  # Real transport over the Darwin CoreBluetooth backend.
  class RealBleLink
    def initialize
      @ble = StackchanCentral.new
      @rx_value_handle = nil
      @pending = []
    end

    def connected?
      !@rx_value_handle.nil? &&
        @ble.conn_handle != BLE::HCI_CON_HANDLE_INVALID
    end

    # Scan -> connect -> discover (all driven inside scan/connect's event loop) ->
    # bind the NUS RX value handle. Returns true once the RX handle is bound.
    def connect
      if connected?
        # Emit the same status line as a fresh success: the Swift UI derives
        # its connected/failed state from this exact string, so a silent early
        # return would flip the status to "connect failed" on a re-tap.
        print "Connected; RX value_handle bound\n"
        return true
      end
      print "Scanning for Stack-chan (NUS)\n"
      # On the Simulator no peripheral answers; scan simply times out.
      @ble.scan(timeout_ms: SCAN_TIMEOUT_MS)
      bind_rx
      if connected?
        print "Connected; RX value_handle bound\n"
        flush_pending
        true
      else
        print "No Stack-chan found. Check: robot powered on? Bluetooth on?\n"
        false
      end
    end

    # Pump BLE events (drains the Swift FIFO ~one packet per tick).
    def tick
      @ble.start(200) if connected?
      nil
    end

    def write(frame)
      unless connected?
        @pending << frame
        print frame
        return :pending
      end
      @ble.write_value_of_characteristic_without_response(
        @ble.conn_handle, @rx_value_handle, frame
      )
      print frame
      :ok
    end

    private

    # Walk discovered services for the NUS, then its RX characteristic. Match by
    # rendering each discovered :uuid128 (16 big-endian bytes) to hex.
    def bind_rx
      @ble.services.each do |service|
        next unless uuid128_hex(service[:uuid128]) == NUS_SERVICE_UUID128_HEX
        service[:characteristics].each do |chara|
          if uuid128_hex(chara[:uuid128]) == NUS_RX_CHAR_UUID128_HEX
            @rx_value_handle = chara[:value_handle]
            return
          end
        end
      end
    end

    # 16 bytes (big-endian as stored in :uuid128) -> lowercase hex String.
    def uuid128_hex(bytes)
      return "" unless bytes && bytes.bytesize == 16
      hex = ""
      i = 0
      while i < 16
        b = bytes.getbyte(i) || 0
        hex += HEX_DIGITS[(b >> 4), 1]
        hex += HEX_DIGITS[b & 0x0f, 1]
        i += 1
      end
      hex
    end

    def flush_pending
      until @pending.empty?
        write(@pending.shift)
      end
    end
  end
end

# The dispatcher object the persistent-VM bridge calls. vm_call(method, arg)
# invokes one of these with a single String arg from the Swift UI.
#
# Every method prints a prefixed status line (face: / led: / head:) that the
# Swift UI parses out of the captured output. The BLE links echo each frame they
# write, so the status line is NOT the only line in the output — the UI matches
# on the prefix, not on the whole string.
class Stackchan
  # Colours led_toggle picks from. "white" and "off" are excluded: neither reads
  # as "the LED lit up in a random colour".
  LED_RANDOM_COLORS = ["red", "green", "blue", "yellow", "cyan", "magenta"]

  # The two happy faces the watch cycles between.
  FACE_A = "smile"
  FACE_B = "joy"

  # head_sweep's waypoints. Each frame asks the servo for a 500 ms move; the
  # pacing sleep is a little longer so one move finishes before the next starts.
  SWEEP_MAGNITUDE_YAW   = 60
  SWEEP_MAGNITUDE_PITCH = 40
  SWEEP_MOVE_MS         = 500
  SWEEP_PACE_MS         = 600
  SWEEP_NEUTRAL_MS      = 400

  attr_reader :ble

  def initialize(ble = nil)
    @ble = ble || (BLE_AVAILABLE ? RealBleLink.new : BleLink.new)
    @face_state = FACE_A
    @led_on = false
  end

  # Scan/connect/discover/bind the Stack-chan's NUS RX. arg is ignored (vm_call
  # always passes one String). Returns nothing; output is captured via print.
  # Expected failures (robot absent, BLE layer errors) become a one-line
  # message here; an uncaught exception would otherwise surface as a raw
  # backtrace in the log (the bridge's safety net for real bugs).
  def connect(arg = nil)
    begin
      @ble.connect
    rescue => e
      print "Connect failed: #{e.class}: #{e.message}\n"
    end
    nil
  end

  # Pump BLE events. Posted periodically by the Swift VM-owner thread.
  def tick(arg = nil)
    begin
      @ble.tick
    rescue => e
      print "tick error: #{e.class}: #{e.message}\n"
    end
    nil
  end

  # Flip between the two happy faces and send the frame. Prints "face:<name>".
  def face_toggle(arg = nil)
    @face_state = (@face_state == FACE_A ? FACE_B : FACE_A)
    @ble.write(FrameCodec.encode_face(@face_state))
    print "face:#{@face_state}\n"
    nil
  end

  # Toggle the LED. On: pick a random colour and blink both sides. Off: send the
  # off frame. Prints "led:on:<color>" or "led:off".
  def led_toggle(arg = nil)
    @led_on = !@led_on
    if @led_on
      color = LED_RANDOM_COLORS[rand(LED_RANDOM_COLORS.length)]
      @ble.write(FrameCodec.encode_led(color: color, side: "both", mode: "blink"))
      print "led:on:#{color}\n"
    else
      @ble.write(FrameCodec.encode_led(color: "off", side: "both", mode: "off"))
      print "led:off\n"
    end
    nil
  end

  # Sweep the head left, right, up, then back to neutral. Blocks the VM thread
  # for roughly SWEEP_PACE_MS * 3 by design; the UI keeps this single-flight.
  # Prints "head:done".
  def head_sweep(arg = nil)
    @ble.write(FrameCodec.encode_head(yaw_left: SWEEP_MAGNITUDE_YAW, time_ms: SWEEP_MOVE_MS))
    msleep(SWEEP_PACE_MS)
    @ble.write(FrameCodec.encode_head(yaw_right: SWEEP_MAGNITUDE_YAW, time_ms: SWEEP_MOVE_MS))
    msleep(SWEEP_PACE_MS)
    @ble.write(FrameCodec.encode_head(pitch_up: SWEEP_MAGNITUDE_PITCH, time_ms: SWEEP_MOVE_MS))
    msleep(SWEEP_PACE_MS)
    @ble.write(FrameCodec.encode_head(yaw_left: 0, pitch_up: 0, time_ms: SWEEP_NEUTRAL_MS))
    print "head:done\n"
    nil
  end
end

$app = Stackchan.new
