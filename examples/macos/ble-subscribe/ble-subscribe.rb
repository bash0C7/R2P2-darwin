# A BLE central for the macOS host. It scans for a peripheral whose name
# includes TARGET_NAME (default "PicoRuby"), connects, discovers its services,
# subscribes to the first characteristic that notifies, and prints every
# notification until the scan window (SCAN_MS, default 40000) closes. The
# picoruby-ble peripheral example on a Pico W / Pico 2 W is the intended peer.

require "env"
require "ble"

class SubscribeCentral < BLE
  def initialize(target_name)
    super(:central)
    @target_name = target_name
    @picked = false
    @subscribed = false
  end

  def advertising_report_callback(report)
    return if @picked || !report.name_include?(@target_name)
    @picked = true
    puts report.format
    connect(report)
  end

  def packet_callback(event_packet)
    super
    if event_packet.getbyte(0) == GATT_EVENT_NOTIFICATION
      handle = Utils.little_endian_to_int16(event_packet.byteslice(4, 2))
      length = Utils.little_endian_to_int16(event_packet.byteslice(6, 2))
      value = event_packet.byteslice(8, length) || ""
      puts "Notification from handle #{handle}: #{value.inspect} (#{hex_bytes(value)})"
    end
    subscribe if @state == :TC_IDLE && !@subscribed
  end

  def subscribe
    @subscribed = true
    chara = notifying_characteristic
    unless chara
      puts "No characteristic with NOTIFY"
      return
    end
    cccd = client_characteristic_configuration(chara)
    unless cccd
      puts "No CCCD under value handle #{chara[:value_handle]}"
      return
    end
    puts "Subscribing to value handle #{chara[:value_handle]} through CCCD handle #{cccd[:handle]}"
    write_characteristic_descriptor_using_descriptor_handle(@conn_handle, cccd[:handle], "\x01\x00")
  end

  def notifying_characteristic
    services.each do |service|
      service[:characteristics].each do |chara|
        return chara if (chara[:properties] & NOTIFY) != 0
      end
    end
    nil
  end

  def client_characteristic_configuration(chara)
    chara[:descriptors].each do |desc|
      return desc if desc[:uuid128].byteslice(0, 4) == "\x00\x00\x29\x02"
    end
    nil
  end

  def hex_bytes(value)
    value.bytes.map { |b| sprintf("%02X", b) }.join(" ")
  end
end

central = SubscribeCentral.new(ENV["TARGET_NAME"] || "PicoRuby")
central.scan(timeout_ms: (ENV["SCAN_MS"] || "40000").to_i, stop_state: :no_stop)
