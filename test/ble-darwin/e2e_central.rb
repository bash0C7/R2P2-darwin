# End-to-end test: drive the real CoreBluetooth central against ANY BLE peripheral
# (the Swift fixture, or an iOS/Android app like nRF Connect) over the live radio.
#
#   1) start a peripheral on a SECOND device (same-Mac loopback does NOT work):
#        - 2nd Mac:  swiftc test/ble-darwin/test_peripheral.swift -o test_peripheral && ./test_peripheral
#        - iOS:      nRF Connect -> advertise a GATT server with a readable characteristic
#   2) build-ble/host/bin/picoruby test/ble-darwin/e2e_central.rb
#
# Target selection (robust to peripherals that don't advertise a name):
#   - If TARGET_NAME is non-empty and a device advertises it, connect to that.
#   - Otherwise connect to the STRONGEST-RSSI device seen (place the peripheral
#     device right on top of the Mac so it is the closest/strongest).
# PASS = connected, >=1 service discovered, and >=1 characteristic value read.

TARGET_NAME = "PBLE-TEST"   # set to "" to always use strongest-RSSI selection
SCAN_MS     = 12000

class E2ECentral < BLE
  attr_reader :picked
  def initialize(role)
    super
    @seen = []           # [[rssi, address, address_type, name]]
    @picked = nil
  end

  def advertising_report_callback(r)
    return unless @state == :TC_W4_SCAN_RESULT
    name = r.reports[:complete_local_name] || r.reports[:shortened_local_name]
    @seen << [r.rssi, r.address, r.address_type_code, name]
    if !TARGET_NAME.empty? && name && name.include?(TARGET_NAME)
      pick(r.address, r.address_type_code, name, r.rssi)
    end
  end

  def pick(addr, atype, name, rssi)
    return if @picked
    @picked = [addr, atype, name, rssi]
    STDOUT.puts "[central] connecting to #{name.inspect} rssi=#{rssi}"
    stop_scan
    @state = :TC_W4_CONNECT
    gap_connect(addr, atype)
  end

  def connect_strongest
    best = nil
    @seen.each { |e| best = e if best.nil? || e[0] > best[0] }
    return false unless best
    STDOUT.puts "[central] no name match; strongest device rssi=#{best[0]} name=#{best[3].inspect}"
    pick(best[1], best[2], best[3], best[0])
    true
  end
end

c = E2ECentral.new(:central)
# Phase 1: scan. If a named target appears, advertising_report_callback connects
# immediately and the loop runs through discovery to :TC_IDLE.
c.scan(timeout_ms: SCAN_MS, stop_state: :TC_IDLE, debug: true)

# Phase 2: if nothing was picked by name, connect to the strongest device and
# run discovery in a fresh poll loop.
unless c.picked
  if c.connect_strongest
    c.start(15000, :TC_IDLE)
  else
    STDOUT.puts "[central] no devices seen at all (check Bluetooth permission)"
  end
end

svcs = c.services
STDOUT.puts "[central] discovery done; state=#{c.state} services=#{svcs.size}"
read_any = false
svcs.each do |s|
  STDOUT.puts "  svc uuid32=#{sprintf('0x%08X', s[:uuid32] || 0)} #{s[:start_handle]}..#{s[:end_handle]}"
  s[:characteristics].each do |ch|
    read_any = true unless ch[:value].nil?
    STDOUT.puts "    char uuid32=#{sprintf('0x%08X', ch[:uuid32] || 0)} vh=#{ch[:value_handle]} props=#{ch[:properties]} value=#{ch[:value].inspect}"
    ch[:descriptors].each do |d|
      STDOUT.puts "      desc uuid32=#{sprintf('0x%08X', d[:uuid32] || 0)} handle=#{d[:handle]} value=#{d[:value].inspect}"
    end
  end
end

if svcs.size > 0 && read_any
  STDOUT.puts "E2E PASS: connect -> discover -> read characteristic value end-to-end"
else
  STDOUT.puts "E2E FAIL: services=#{svcs.size} read_any=#{read_any} (see trace above)"
end
