# Stack-chan controller — the bundled, fixed Ruby that the persistent PicoRuby
# VM runs on iOS. This is NOT user-editable and is not downloaded: PicoRuby is
# simply the implementation language for the app's own behavior (Guideline
# 2.5.2-free).
#
# The frame encoders are inlined from the PC CLI's verified codec
# (stackchan-picoruby/pc/stackchan/lib/stackchan/ble/{frame_codec,face_table,
# led_color_table}.rb). Two adaptations for the reduced iOS VM and the
# Swift->VM call seam:
#   1. No require_relative / module namespacing — the bundled app is one source.
#   2. String keys (not Symbols) because vm_call delivers a single String arg
#      from the Swift UI. The emitted frames are byte-identical to the PC codec.
#
# The wire frame format and the left/right reversal are load-bearing and were
# verified on real hardware; do not "fix" SIDE_TO_CHAR.

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
  TOUCH_PREFIX = "<touch:"

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

  def self.encode_torque(on)
    encode_pairs({ "torque" => (on ? "on" : "off") })
  end

  # frame[0,1] is safe on a bare 1-char ACK byte too.
  def self.parse_ack(frame)
    case frame[0, 1]
    when ACK_OK    then :ok
    when ACK_ERROR then :error
    else raise ArgumentError, "unknown ack frame: #{frame}"
    end
  end

  # Reduced VM has no Regexp; parse "<touch:N>" by hand. Returns the zone Integer
  # or nil if the frame is not a touch event.
  def self.parse_touch(frame)
    return nil unless frame[0, TOUCH_PREFIX.length] == TOUCH_PREFIX
    rest = frame[TOUCH_PREFIX.length, frame.length]
    digits = ""
    i = 0
    while i < rest.length
      c = rest[i, 1]
      break unless c >= "0" && c <= "9"
      digits += c
      i += 1
    end
    return nil if digits.empty?
    digits.to_i
  end
end

# The BLE transport seam.
#
# `RealBleLink` (below) drives picoruby-ble's central role over the Darwin
# (CoreBluetooth) port: it scans for a Stack-chan advertising the Nordic UART
# Service (NUS), connects, discovers the RX characteristic value handle, and
# writes each ASCII frame to it. picoruby-ble is only present in the on-device /
# Simulator VM, so this file guards every reference behind `BLE_AVAILABLE`
# (see above): under host CRuby (test_frames.rb) BLE is absent and the recording
# `BleLink` stub is used instead, keeping the frame encoders verifiable without a
# radio.

# The Nordic UART Service and its RX (write) characteristic, the Stack-chan
# firmware's command channel. `BLE::Utils.uuid` yields the 16-byte little-endian
# form that the discovered service/characteristic `uuid128` fields also use, so
# the two compare directly.
NUS_SERVICE_UUID = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
NUS_RX_CHAR_UUID = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
# Substring matched against the advertised local name to pick the robot.
STACKCHAN_NAME = "StackChan"

# Is the picoruby-ble `BLE` class linked into this VM? The reduced PicoRuby VM
# (prism compiler) does NOT implement the `defined?` keyword — it compiles
# `defined?(BLE)` as a method call that raises at boot — so probe for the
# constant by referencing it and rescuing the NameError. True in the on-device /
# Simulator VM (picoruby-ble linked); false under host CRuby (test_frames.rb),
# which then falls back to the recording `BleLink` stub.
BLE_AVAILABLE =
  begin
    BLE
    true
  rescue NameError
    false
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
      return true if connected?
      print "Scanning for Stack-chan (NUS)\n"
      # On the Simulator no peripheral answers; scan simply times out.
      @ble.scan(timeout_ms: 5000)
      bind_rx
      if connected?
        print "Connected; RX value_handle bound\n"
        flush_pending
        true
      else
        print "No Stack-chan found\n"
        false
      end
    end

    # Pump BLE events (drains the Swift FIFO ~one packet per 100ms tick).
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
      # `frame` is already an ASCII String; the BLE write takes a String and
      # sends its raw bytes (mrb_get_args "iiS" -> RSTRING_PTR/LEN). The reduced
      # VM has no Array#pack, so do not round-trip through bytes.
      @ble.write_value_of_characteristic_without_response(
        @ble.conn_handle, @rx_value_handle, frame
      )
      print frame
      :ok
    end

    private

    # Walk discovered services for the NUS, then its RX characteristic.
    def bind_rx
      want_service = BLE::Utils.uuid(NUS_SERVICE_UUID)
      want_rx      = BLE::Utils.uuid(NUS_RX_CHAR_UUID)
      @ble.services.each do |service|
        next unless service[:uuid128] == want_service
        service[:characteristics].each do |chara|
          if chara[:uuid128] == want_rx
            @rx_value_handle = chara[:value_handle]
            return
          end
        end
      end
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
class Stackchan
  attr_reader :ble

  def initialize(ble = nil)
    @ble = ble || (BLE_AVAILABLE ? RealBleLink.new : BleLink.new)
  end

  # Scan/connect/discover/bind the Stack-chan's NUS RX. arg is ignored (vm_call
  # always passes one String). Returns nothing; output is captured via print.
  def connect(arg = nil)
    @ble.connect
    nil
  end

  # Pump BLE events. Posted periodically by the Swift VM-owner thread.
  def tick(arg = nil)
    @ble.tick
    nil
  end

  # arg: a face name, e.g. "joy".
  def face(arg)
    @ble.write(FrameCodec.encode_face(arg))
  end

  # arg: "color" or "color:mode" or "color:mode:side"
  # (defaults mode=solid, side=both), e.g. "red", "red:blink", "green:solid:left".
  def led(arg)
    parts = arg.split(":")
    color = parts[0]
    mode  = parts[1] || "solid"
    side  = parts[2] || "both"
    @ble.write(FrameCodec.encode_led(color: color, side: side, mode: mode))
  end

  # arg: "dir:magnitude" or "dir:magnitude:time_ms"; dir is "left"/"right"/"up",
  # magnitude 0..100, e.g. "left:50:500".
  def head(arg)
    parts = arg.split(":")
    dir = parts[0]
    mag = parts[1] ? parts[1].to_i : 0
    t   = parts[2] ? parts[2].to_i : nil
    case dir
    when "left"  then @ble.write(FrameCodec.encode_head(yaw_left: mag, time_ms: t))
    when "right" then @ble.write(FrameCodec.encode_head(yaw_right: mag, time_ms: t))
    when "up"    then @ble.write(FrameCodec.encode_head(pitch_up: mag, time_ms: t))
    else raise ArgumentError, "unknown head dir: #{dir}"
    end
  end

  # arg: "on" / "off".
  def torque(arg)
    @ble.write(FrameCodec.encode_torque(arg == "on"))
  end
end

$app = Stackchan.new
