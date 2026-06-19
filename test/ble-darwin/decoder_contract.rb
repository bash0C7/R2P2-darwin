# Contract test: the BTstack-format byte layouts the Darwin port synthesizes are
# decoded by the real ble_central.rb into the correct @services tree, reaching
# :TC_IDLE. Runs on the host BLE binary; no radio. The byte vectors below are the
# exact ones the Swift builders emit, so this closes the loop Swift-bytes -> decoder.
#
#   build-ble/host/bin/picoruby test/ble-darwin/decoder_contract.rb

$failures = 0
def check(name, got, want)
  if got == want
    puts "ok   - #{name}"
  else
    puts "FAIL - #{name}\n        got:  #{got.inspect}\n        want: #{want.inspect}"
    $failures += 1
  end
end

# 16-bit UUID -> 16-byte wire (LSB-first), same as Swift pbleUuidWire(fromCBUUIDData:).
def wire16(x)
  [0xFB,0x34,0x9B,0x5F,0x80,0x00,0x00,0x80,0x00,0x10,0x00,0x00, x & 0xff, (x>>8)&0xff, 0x00, 0x00].pack("C*")
end
def pkt(bytes); bytes.pack("C*"); end

# A central whose port ABI calls are no-ops so packet_callback advances purely on
# the packets we feed; helper sets the FSM into the service-discovery phase.
class TBLE < BLE
  def gap_local_bd_addr; "\x00\x00\x00\x00\x00\x00"; end
  def start_scan; end
  def stop_scan; end
  def discover_primary_services(_c); 0; end
  def discover_characteristics_for_service(_c, _s, _e); 0; end
  def read_value_of_characteristic_using_value_handle(_c, _v); 0; end
  def discover_characteristic_descriptors(_c, _v, _e); 0; end
  def goto_service_phase; @conn_handle = 0x40; @state = :TC_W4_SERVICE_RESULT; end
end

b = TBLE.new(:central)
b.goto_service_phase

# GATT tree (pre-order DFS handles): service[1..6] uuid 0x180D >
#   char A: start=2 value=3 end=4 props=READ uuid 0x2A37, value "hr!",
#           descriptor handle=4 uuid 0x2902 value "cc";
#   char B: start=5 value=6 end=6 props=READ uuid 0x2A38, value "xy".
# The port batches reads of every readable value handle, emitting a single 0xA0
# only after the LAST handle (max), so the decoder files every characteristic's
# value instead of dropping the 2nd+ when an early 0xA0 ends the phase.
svc_uuid   = wire16(0x180D)
charA_uuid = wire16(0x2A37)
charB_uuid = wire16(0x2A38)
desc_uuid  = wire16(0x2902)

seq = [
  pkt([0xA1,0x01,0,0, 1,0, 6,0] + svc_uuid.bytes),                    # service result (1..6)
  pkt([0xA0,0x01]),                                                   # service query complete -> discover chars
  pkt([0xA2,0x01,0,0, 2,0, 3,0, 4,0, 0x02,0] + charA_uuid.bytes),     # char A result
  pkt([0xA2,0x01,0,0, 5,0, 6,0, 6,0, 0x02,0] + charB_uuid.bytes),     # char B result
  pkt([0xA0,0x01]),                                                   # char query complete -> read value 3
  pkt([0xA5,0x01,0,0, 3,0, 3,0, 0x68,0x72,0x21]),                     # batched value handle 3 = "hr!" -> read 6
  pkt([0xA5,0x01,0,0, 6,0, 2,0, 0x78,0x79]),                          # batched value handle 6 = "xy" (last)
  pkt([0xA0,0x01]),                                                   # batched value complete -> discover descriptors (char A)
  pkt([0xA4,0x01,0,0, 4,0] + desc_uuid.bytes),                        # descriptor result handle 4
  pkt([0xA0,0x01]),                                                   # descriptor discovery complete -> read descriptor 4
  pkt([0xA5,0x01,0,0, 4,0, 2,0, 0x63,0x63]),                          # batched descriptor value handle 4 = "cc" (last)
  pkt([0xA0,0x01]),                                                   # batched descriptor-value complete -> TC_IDLE
]
seq.each { |p| b.packet_callback(p) }

check("reaches TC_IDLE", b.state, :TC_IDLE)
check("one service", b.services.size, 1)

svc = b.services[0]
check("service start_handle", svc[:start_handle], 1)
check("service uuid128 canonical", svc[:uuid128].bytes,
      [0x00,0x00,0x18,0x0D,0x00,0x00,0x10,0x00,0x80,0x00,0x00,0x80,0x5F,0x9B,0x34,0xFB])
check("service uuid32 (Base-UUID quirk)", svc[:uuid32], 0x0D180000)
check("two characteristics", svc[:characteristics].size, 2)

chrA = svc[:characteristics][0]
check("char A value_handle", chrA[:value_handle], 3)
check("char A properties", chrA[:properties], 0x02)
check("char A value decoded", chrA[:value], "hr!")
check("char A one descriptor", chrA[:descriptors].size, 1)

chrB = svc[:characteristics][1]
check("char B value_handle", chrB[:value_handle], 6)
check("char B value decoded", chrB[:value], "xy")

dsc = chrA[:descriptors][0]
check("char A descriptor handle", dsc[:handle], 4)
check("char A descriptor uuid32 (CCCD 0x2902 quirk)", dsc[:uuid32], 0x02290000)
check("char A descriptor value decoded", dsc[:value], "cc")

if $failures > 0
  puts "\n#{$failures} check(s) FAILED"
  exit 1
else
  puts "\nALL CHECKS PASS"
end
