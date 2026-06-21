# VirtualPeripheral — a BLE Heart Rate peripheral whose whole GATT-server behaviour
# is driven from Ruby. `class VirtualPeripheral < BLE` (role :peripheral); the
# picoruby-ble Darwin port turns these Ruby calls into CoreBluetooth operations.
# Ruby owns: the GATT profile, when to advertise, what each read returns, how writes
# are handled, when to notify. CoreBluetooth (the Apple framework) is driven through
# the port — this app contains no Swift and no CoreBluetooth code.
#
# PicoRuby's String/Array here do not carry Array#pack / String#<< / Integer#chr
# (this is PicoRuby, not CRuby). So the ATT-DB profile_data and the AD-TLV adv_data
# are built below with their bit-operation equivalents: an int->byte is a slice into
# a 256-byte table (BYTE_TABLE[n, 1], standing in for pack("C")/chr), little-endian
# is `byte(v) + byte(v >> 8)`, and concatenation is `+`. The bytes produced are
# identical to what BLE::GattDatabase / BLE::AdvertisingData emit on rp2040.

# The one irreducible primitive: turning an Integer (0..255) into a 1-byte String.
# Without pack/chr, materialising a byte needs a string that already holds it, so we
# index this fixed table. `BYTE_TABLE[n & 0xff, 1]` is the pack("C") / chr equivalent.
BYTE_TABLE = "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f\x20\x21\x22\x23\x24\x25\x26\x27\x28\x29\x2a\x2b\x2c\x2d\x2e\x2f\x30\x31\x32\x33\x34\x35\x36\x37\x38\x39\x3a\x3b\x3c\x3d\x3e\x3f\x40\x41\x42\x43\x44\x45\x46\x47\x48\x49\x4a\x4b\x4c\x4d\x4e\x4f\x50\x51\x52\x53\x54\x55\x56\x57\x58\x59\x5a\x5b\x5c\x5d\x5e\x5f\x60\x61\x62\x63\x64\x65\x66\x67\x68\x69\x6a\x6b\x6c\x6d\x6e\x6f\x70\x71\x72\x73\x74\x75\x76\x77\x78\x79\x7a\x7b\x7c\x7d\x7e\x7f\x80\x81\x82\x83\x84\x85\x86\x87\x88\x89\x8a\x8b\x8c\x8d\x8e\x8f\x90\x91\x92\x93\x94\x95\x96\x97\x98\x99\x9a\x9b\x9c\x9d\x9e\x9f\xa0\xa1\xa2\xa3\xa4\xa5\xa6\xa7\xa8\xa9\xaa\xab\xac\xad\xae\xaf\xb0\xb1\xb2\xb3\xb4\xb5\xb6\xb7\xb8\xb9\xba\xbb\xbc\xbd\xbe\xbf\xc0\xc1\xc2\xc3\xc4\xc5\xc6\xc7\xc8\xc9\xca\xcb\xcc\xcd\xce\xcf\xd0\xd1\xd2\xd3\xd4\xd5\xd6\xd7\xd8\xd9\xda\xdb\xdc\xdd\xde\xdf\xe0\xe1\xe2\xe3\xe4\xe5\xe6\xe7\xe8\xe9\xea\xeb\xec\xed\xee\xef\xf0\xf1\xf2\xf3\xf4\xf5\xf6\xf7\xf8\xf9\xfa\xfb\xfc\xfd\xfe\xff".freeze

# Heart Rate profile UUIDs (BLE::READ/WRITE/NOTIFY/DYNAMIC and the GATT declaration
# UUIDs come from the linked picoruby-ble gem).
HR_SERVICE       = 0x180D
HR_MEASUREMENT   = 0x2A37   # READ | NOTIFY (+ CCCD)
HR_CONTROL_POINT = 0x2A39   # WRITE

# ATT handles are assigned in build order by add_service/add_characteristic/
# add_descriptor below: service=1, 0x2A37 decl=2, value=3, CCCD=4, 0x2A39 decl=5,
# value=6. The live behaviour addresses the value handles and the CCCD.
HR_MEAS_HANDLE = 3
CCCD_HANDLE    = 4
CONTROL_HANDLE = 6

class VirtualPeripheral < BLE
  def initialize
    profile = build_profile
    super(:peripheral, profile)
    @adv = build_adv
    @log = []
    @subscribed = false
    @awaiting_send = false
    @bpm = 60
    # Seed the read cache so a read before any subscription returns a value.
    push_read_value(HR_MEAS_HANDLE, hr_measurement(@bpm))
    hci_power_control(HCI_POWER_ON)
    log "booted: powering on radio, profile #{profile.length}B"
  end

  # One poll iteration. The Swift timer calls this ~10x/sec. pop_packet drains one
  # CoreBluetooth event (and, on Darwin, reconciles the read cache / write queue on
  # this VM thread). Returns nothing; prints accumulated log lines as captured stdout.
  def tick(arg = nil)
    pkt = pop_packet
    packet_callback(pkt) if pkt
    poll_cccd
    poll_control_point
    # Drive a steady notification stream while a central is subscribed: ask the
    # stack when it can send, and emit the next measurement on CAN_SEND_NOW (0xB7).
    if @subscribed && !@awaiting_send
      request_can_send_now_event
      @awaiting_send = true
    end
    flush_log
  end

  # The four peripheral-role events the Darwin port forwards (see ports/darwin/README).
  def packet_callback(event)
    case event.getbyte(0)
    when 0x60   # BTSTACK_EVENT_STATE: services added, radio working
      advertise(@adv)
      log "radio working -> advertising as PBLE-TEST"
    when 0x05   # disconnection
      @subscribed = false
      @awaiting_send = false
      log "central disconnected"
    when 0xB5   # MTU exchange complete: first subscription from a central
      log "mtu exchanged (central present)"
    when 0xB7   # CAN_SEND_NOW: the moment to push one notification
      @bpm += 1
      @bpm = 60 if @bpm > 180
      push_read_value(HR_MEAS_HANDLE, hr_measurement(@bpm))
      notify(HR_MEAS_HANDLE)
      @awaiting_send = false
      log "notified hr=#{@bpm}"
    end
  end

  private

  # --- GATT profile / advertising built at runtime, pack-free ----------------------
  # int (0..255) -> 1-byte String. The pack("C") / chr equivalent (see BYTE_TABLE).
  def byte(n)
    BYTE_TABLE[n & 0xff, 1]
  end

  # 16-bit little-endian. Utils.int16_to_little_endian's bit-operation equivalent.
  def le16(v)
    byte(v & 0xff) + byte((v >> 8) & 0xff)
  end

  # Allocate the next ATT handle (mirrors GattDatabase#push_handle).
  def push_handle
    @handle += 1
    le16(@handle)
  end

  # Wrap one ATT-DB record with its little-endian length prefix (length includes
  # the 2-byte prefix itself), as GattDatabase#add_line does.
  def gatt_line(line)
    le16(line.length + 2) + line
  end

  def add_service(primary_uuid, service_uuid)
    gatt_line(le16(READ) + push_handle + le16(primary_uuid) + le16(service_uuid))
  end

  def add_characteristic(properties, uuid, value_properties, value)
    decl = le16(READ) + push_handle + le16(GATT_CHARACTERISTIC_UUID) +
           byte(properties & 0xff) + le16(@handle + 1) + le16(uuid)
    val  = le16(value_properties) + push_handle + le16(uuid) + value
    gatt_line(decl) + gatt_line(val)
  end

  def add_descriptor(properties, uuid, value)
    gatt_line(le16(properties) + push_handle + le16(uuid) + value)
  end

  # The BTstack ATT-DB blob for the Heart Rate profile, assembled the same way
  # GattDatabase does — just with byte()/le16()/+ instead of pack/<<.
  def build_profile
    @handle = 0
    body = byte(0x01)   # ATT_DB_VERSION
    body += add_service(GATT_PRIMARY_SERVICE_UUID, HR_SERVICE)
    body += add_characteristic(READ | NOTIFY | DYNAMIC, HR_MEASUREMENT, READ | DYNAMIC, "\x00\x00")
    body += add_descriptor(READ | WRITE | DYNAMIC, CLIENT_CHARACTERISTIC_CONFIGURATION, "\x00\x00")
    body += add_characteristic(WRITE | DYNAMIC, HR_CONTROL_POINT, WRITE | DYNAMIC, "\x00")
    body + "\x00\x00"   # database terminator
  end

  # One advertising-data element: [length][type][payload], length counts type+payload.
  def adv_field(type, payload)
    byte(1 + payload.length) + byte(type) + payload
  end

  # Flags (LE General Discoverable, BR/EDR not supported) + the 16-bit HR service
  # UUID + the complete local name. AdvertisingData.build's bit-operation equivalent.
  def build_adv
    adv_field(0x01, byte(0x06)) +
      adv_field(0x03, le16(HR_SERVICE)) +
      adv_field(0x09, "PBLE-TEST")
  end

  # --- live GATT-server behaviour --------------------------------------------------
  # CCCD write toggles subscription. Canonical path: pop_write_value(cccd) returns
  # "\x01\x00" (subscribe) or "\x00\x00" (unsubscribe).
  def poll_cccd
    v = pop_write_value(CCCD_HANDLE)
    return unless v
    if v.getbyte(0) == 0x01
      @subscribed = true
      @awaiting_send = false
      log "subscribed -> streaming heart rate"
    else
      @subscribed = false
      log "unsubscribed"
    end
  end

  # A write to the Heart Rate Control Point (0x2A39). 0x01 = "reset energy expended";
  # here we just log it and reset the simulated rate, proving Ruby sees the bytes.
  def poll_control_point
    v = pop_write_value(CONTROL_HANDLE)
    return unless v
    log "control point write: #{hex(v)}"
    if v.length > 0 && v.getbyte(0) == 0x01
      @bpm = 60
      log "  -> reset heart rate to 60"
    end
  end

  # Heart Rate Measurement value: flags byte 0x00 (UINT8 BPM, no extras) + the rate.
  def hr_measurement(bpm)
    byte(0x00) + byte(bpm)
  end

  # Hex-encode a binary string for logging (no sprintf in this VM).
  def hex(s)
    digits = "0123456789abcdef"
    out = ""
    i = 0
    while i < s.length
      b = s.getbyte(i)
      out += digits[(b >> 4) & 0x0f, 1]
      out += digits[b & 0x0f, 1]
      i += 1
    end
    out
  end

  def log(msg)
    @log.push(msg)
  end

  def flush_log
    return nil if @log.empty?
    out = @log.join("\n")
    @log = []
    print out
    nil
  end
end

$app = VirtualPeripheral.new
