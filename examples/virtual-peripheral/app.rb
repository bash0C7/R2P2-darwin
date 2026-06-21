# Virtual BLE peripheral — the PicoRuby brain. The Swift CBPeripheralManager
# (Sources/PeripheralManager.swift) is only the radio: at power-on it asks this
# object for the GATT profile to publish, then forwards every central event
# (read, write, subscribe) here and applies whatever this object emits. ALL
# device behavior — which services exist, what a read returns, how a write is
# answered, what gets notified — is decided here, in Ruby. That is the point of
# this example: a BLE peripheral app built PicoRuby-first.
#
# The bridge's vm_call returns CAPTURED STDOUT (not the return value), so every
# handler `print`s its protocol string. Characteristic values cross the bridge
# as lowercase hex ASCII (the C-string return cannot carry NUL bytes). The
# reduced PicoRuby VM has no Regexp / Array#pack / defined?, so hex is built and
# parsed by hand below.

module Hex
  DIGITS = "0123456789abcdef"

  # Integer (0..255) -> 2 lowercase hex chars.
  def self.byte_to_hex(b)
    DIGITS[b >> 4, 1] + DIGITS[b & 15, 1]
  end

  # ASCII String -> lowercase hex (2 chars per byte).
  def self.ascii_to_hex(str)
    out = ""
    i = 0
    while i < str.length
      out += byte_to_hex(str[i, 1].ord)
      i += 1
    end
    out
  end

  # 1 lowercase hex char -> its 0..15 value.
  def self.nibble(c)
    DIGITS.index(c)
  end

  # lowercase hex String -> ASCII String.
  def self.to_ascii(hex)
    out = ""
    i = 0
    n = hex.length
    while i + 2 <= n
      out += (nibble(hex[i, 1]) * 16 + nibble(hex[i + 1, 1])).chr
      i += 2
    end
    out
  end
end

# ---- GATT profiles (data) ---------------------------------------------------
# A profile is a Hash: "name" + "services" => [[service_uuid, [[char_uuid,
# props], ...]], ...]. UUIDs: 16-bit as 4 lowercase hex chars ("180d"); 128-bit
# as the full lowercase dashed string. props is any of "r"/"w"/"n".
DEVICE_NAME = "PBLE-TEST"

HEART_RATE_PROFILE = {
  "name" => DEVICE_NAME,
  "services" => [
    ["180d", [
      ["2a37", "n"],   # Heart Rate Measurement (notify)
      ["2a38", "r"],   # Body Sensor Location (read)
      ["2a39", "w"],   # Heart Rate Control Point (write)
    ]],
  ],
}

NUS_PROFILE = {
  "name" => DEVICE_NAME,
  "services" => [
    ["6e400001-b5a3-f393-e0a9-e50e24dcca9e", [
      ["6e400002-b5a3-f393-e0a9-e50e24dcca9e", "w"],  # RX: central writes here
      ["6e400003-b5a3-f393-e0a9-e50e24dcca9e", "n"],  # TX: we notify here
    ]],
  ],
}

# Choose the profile to publish, then relaunch. No runtime switch (YAGNI).
ACTIVE_PROFILE = HEART_RATE_PROFILE

# The dispatcher the bridge calls: vm_call(method, arg) invokes one of these
# with a single String arg. Each method prints its protocol string.
class VirtualPeripheral
  HR_MEASUREMENT = "2a37"
  HR_BODY_LOC    = "2a38"
  HR_CONTROL_PT  = "2a39"
  NUS_RX = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
  NUS_TX = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"

  def initialize(profile)
    @profile = profile
    @subscribed = {}   # char_uuid => true/false
    @bpm = 60
  end

  # Serialize the active profile for Swift to build the GATT tree. Lines:
  # "NAME <name>", "SERVICE <uuid>", "CHAR <uuid> <props>".
  def profile(arg = nil)
    out = "NAME #{@profile["name"]}\n"
    @profile["services"].each do |svc|
      out += "SERVICE #{svc[0]}\n"
      svc[1].each do |ch|
        out += "CHAR #{ch[0]} #{ch[1]}\n"
      end
    end
    print out
  end

  # arg: "<char_uuid>". Prints "<value_hex>|<log_line>".
  def on_read(arg)
    if arg == HR_BODY_LOC
      print "01|READ  Body Sensor Location -> Wrist (0x01)"
    else
      print "|READ  #{arg} -> (empty)"
    end
  end

  # arg: "<char_uuid>|<value_hex>". Prints
  # "<resp_char_uuid>:<resp_hex>|<log_line>" (head empty if no response).
  def on_write(arg)
    bar  = arg.index("|")
    uuid = arg[0, bar]
    hex  = arg[bar + 1, arg.length]
    if uuid == NUS_RX
      frame = Hex.to_ascii(hex)
      disp = frame
      disp = frame[0, frame.length - 1] if frame.length > 0 && frame[frame.length - 1, 1] == "\n"
      reply = (frame == "<read:pos>\n") ? "<YL_actual:0,PU_actual:50>\n" : "."
      print "#{NUS_TX}:#{Hex.ascii_to_hex(reply)}|WRITE RX <- #{disp}"
    elsif uuid == HR_CONTROL_PT
      print "|WRITE Heart Rate Control Point <- 0x#{hex} (accepted)"
    else
      print "|WRITE #{uuid} <- 0x#{hex}"
    end
  end

  # arg: "<char_uuid>".
  def on_subscribe(arg)
    @subscribed[arg] = true
    print "SUBSCRIBE #{arg}"
  end

  def on_unsubscribe(arg)
    @subscribed[arg] = false
    print "UNSUBSCRIBE #{arg}"
  end

  # Push periodic notifications for subscribed notify characteristics. Prints
  # zero or more "<char_uuid>:<value_hex>|<log_line>" lines, or nothing.
  def tick(arg = nil)
    return unless @subscribed[HR_MEASUREMENT]
    @bpm += 1
    @bpm = 60 if @bpm > 90
    # Heart Rate Measurement: flags byte 0x00 (uint8 bpm) + bpm byte.
    value_hex = "00" + Hex.byte_to_hex(@bpm)
    print "#{HR_MEASUREMENT}:#{value_hex}|NOTIFY Heart Rate Measurement -> #{@bpm} bpm"
  end
end

$app = VirtualPeripheral.new(ACTIVE_PROFILE)
