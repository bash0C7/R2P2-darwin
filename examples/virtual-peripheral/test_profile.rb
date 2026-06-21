# Host CRuby test for the virtual-peripheral brain. vm_call returns captured
# stdout, so each handler prints its protocol string; here we capture stdout the
# same way. No BLE / Swift — verifies the Ruby protocol logic only. The reduced
# PicoRuby VM is verified separately by the host-libmruby probe.
require "stringio"
require_relative "app"

def capture
  old = $stdout
  $stdout = StringIO.new
  yield
  $stdout.string
ensure
  $stdout = old
end

def assert_eq(actual, expected, msg)
  if actual == expected
    puts "ok - #{msg}"
  else
    puts "FAIL - #{msg}\n  expected: #{expected.inspect}\n  actual:   #{actual.inspect}"
    $failed = true
  end
end

$failed = false

# --- Heart Rate profile ---
hr = VirtualPeripheral.new(HEART_RATE_PROFILE)
assert_eq(capture { hr.profile("") },
          "NAME PBLE-TEST\nSERVICE 180d\nCHAR 2a37 n\nCHAR 2a38 r\nCHAR 2a39 w\n",
          "heart-rate profile serialization")
assert_eq(capture { hr.on_read("2a38") },
          "01|READ  Body Sensor Location -> Wrist (0x01)",
          "body sensor location read")
assert_eq(capture { hr.tick("") }, "", "tick with no subscriber is silent")
hr.on_subscribe("2a37")
assert_eq(capture { hr.tick("") },
          "2a37:003d|NOTIFY Heart Rate Measurement -> 61 bpm",
          "first heart-rate notify is 61 bpm (0x3d)")

# --- NUS profile ---
nus = VirtualPeripheral.new(NUS_PROFILE)
rx = VirtualPeripheral::NUS_RX
tx = VirtualPeripheral::NUS_TX
assert_eq(capture { nus.on_write("#{rx}|#{Hex.ascii_to_hex("<F:2>\n")}") },
          "#{tx}:2e|WRITE RX <- <F:2>",
          "NUS frame write auto-ACKs '.' (0x2e) on TX")
assert_eq(capture { nus.on_write("#{rx}|#{Hex.ascii_to_hex("<read:pos>\n")}") },
          "#{tx}:#{Hex.ascii_to_hex("<YL_actual:0,PU_actual:50>\n")}|WRITE RX <- <read:pos>",
          "read:pos write replies with a detail frame")

exit(1) if $failed
puts "all virtual-peripheral profile tests passed"
