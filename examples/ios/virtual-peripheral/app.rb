# VirtualPeripheral — a BLE Heart Rate peripheral whose whole GATT-server behaviour
# is driven from Ruby. `class VirtualPeripheral < BLE` (role :peripheral); the
# picoruby-ble Darwin port turns these Ruby calls into CoreBluetooth operations.
# Ruby owns: the GATT profile, when to advertise, what each read returns, how writes
# are handled, when to notify. CoreBluetooth (the Apple framework) is driven through
# the port — this app contains no Swift and no CoreBluetooth code.
#
# Event model (upstream picoruby-ble): BLE#start(timeout_ms) is the canonical
# event loop — it powers the radio on, blocks on the internal Task::Queue (legal
# here because the VM bridge dispatches every vm_call inside a task), hands packet
# events to packet_callback and ~1 Hz heartbeats to heartbeat_callback, then powers
# the radio off when the timeout expires. The Swift side calls `tick` continuously;
# each tick is one bounded start() window, so the peripheral sits inside the event
# loop for nearly all wall-clock time.
#
# The GATT profile and the advertising data are built with the canonical
# picoruby-ble builders (BLE::GattDatabase / BLE::AdvertisingData) — the same code
# that builds them on an rp2040 board. The build config carries mruby-pack /
# mruby-string-ext / mruby-sprintf, which those builders (and this file) use.

require "ble"

# Heart Rate profile UUIDs (BLE::READ/WRITE/NOTIFY/DYNAMIC and the GATT declaration
# UUIDs come from the linked picoruby-ble gem).
HR_SERVICE       = 0x180D
HR_MEASUREMENT   = 0x2A37   # READ | NOTIFY (+ CCCD)
HR_CONTROL_POINT = 0x2A39   # WRITE

class VirtualPeripheral < BLE
  # One tick = one bounded event-loop window. 1000 ms keeps the on-screen log
  # fresh while holding advertising restarts (one per window, see tick) to ~1 Hz.
  WINDOW_MS = 1000

  def initialize
    db = BLE::GattDatabase.new do |gatt|
      gatt.add_service(GATT_PRIMARY_SERVICE_UUID, HR_SERVICE) do |service|
        service.add_characteristic(READ | NOTIFY | DYNAMIC, HR_MEASUREMENT,
                                   READ | DYNAMIC, [0, 60].pack("CC")) do |chara|
          chara.add_descriptor(READ | WRITE | DYNAMIC,
                               CLIENT_CHARACTERISTIC_CONFIGURATION, [0, 0].pack("CC"))
        end
        service.add_characteristic(WRITE | DYNAMIC, HR_CONTROL_POINT,
                                   WRITE | DYNAMIC, [0].pack("C"))
      end
    end
    # ATT handles come from the builder's handle table, not hardcoded numbers.
    hr = db.handle_table[HR_SERVICE][HR_MEASUREMENT]
    @meas_handle    = hr[:value_handle]
    @cccd_handle    = hr[CLIENT_CHARACTERISTIC_CONFIGURATION]
    @control_handle = db.handle_table[HR_SERVICE][HR_CONTROL_POINT][:value_handle]
    super(:peripheral, db.profile_data)
    @adv_data = BLE::AdvertisingData.build do |adv|
      adv.add(0x01, 0x06)         # flags: LE General Discoverable, no BR/EDR
      adv.add(0x03, HR_SERVICE)   # 16-bit service UUIDs (ints emit little-endian)
      adv.add(0x09, "PBLE-TEST")  # complete local name
    end
    @services_ready = false   # set on the port's 0x60 (services registered)
    @advertising    = false
    @subscribed     = false
    @awaiting_send  = false
    @bpm = 60
    # Seed the read cache so a read before any subscription returns a value.
    push_read_value(@meas_handle, hr_measurement(@bpm))
    # Boot output is not captured by vm_open (only vm_call captures); this line
    # lands on the process stdout, i.e. the Xcode / console-pty log.
    print "booted: profile #{db.profile_data.length}B, handles: hr=#{@meas_handle} cccd=#{@cccd_handle} control=#{@control_handle}\n"
  end

  # One bounded event-loop window. start()'s ensure powers the radio off on the
  # way out, which stops CoreBluetooth advertising — so each window re-arms
  # advertising on the way in. Expected BLE failures surface as one log line,
  # not a backtrace.
  def tick(arg = nil)
    begin
      if @services_ready && !@advertising
        advertise(@adv_data)
        @advertising = true
      end
      start(WINDOW_MS)
    rescue => e
      print "tick error: #{e.class}: #{e.message}\n"
    end
    # start() powered the radio off (advertising stopped), and any event still
    # queued at the timeout was cleared — including an un-consumed CAN_SEND_NOW —
    # so re-arm the notification pacing too.
    @advertising = false
    @awaiting_send = false
    nil
  end

  # ~1 Hz inside the window (the port's heartbeat timer). Steady-state work
  # happens here, in-window, where the port's event drain is live.
  def heartbeat_callback
    drain_writes
    # Drive a steady notification stream while a central is subscribed: ask the
    # stack when it can send; the answer arrives as CAN_SEND_NOW (0xB7).
    if @subscribed && !@awaiting_send
      request_can_send_now_event
      @awaiting_send = true
    end
  end

  # The four peripheral-role events the Darwin port forwards (see ports/darwin/README).
  def packet_callback(event)
    case event.getbyte(0)
    when 0x60   # BTSTACK_EVENT_STATE: services added, radio working
      @services_ready = true
      advertise(@adv_data)
      @advertising = true
      print "radio working -> advertising as PBLE-TEST\n"
    when 0x05   # disconnection
      @subscribed = false
      @awaiting_send = false
      print "central disconnected\n"
    when 0xB5   # MTU exchange complete: first subscription from a central
      print "mtu exchanged (central present)\n"
    when 0xB7   # CAN_SEND_NOW: the moment to push one notification
      @bpm += 1
      @bpm = 60 if @bpm > 180
      push_read_value(@meas_handle, hr_measurement(@bpm))
      notify(@meas_handle)
      @awaiting_send = false
      print "notified hr=#{@bpm}\n"
    end
  end

  private

  # Writes land in the port's write table (reconciled onto the VM thread inside
  # the window); drain them all. The CCCD toggles the subscription; the Heart
  # Rate Control Point receives command writes.
  def drain_writes
    while true
      v = pop_write_value(@cccd_handle)
      break if v.nil?
      if v.getbyte(0) == 1
        @subscribed = true
        @awaiting_send = false
        print "subscribed -> streaming heart rate\n"
      else
        @subscribed = false
        print "unsubscribed\n"
      end
    end
    while true
      v = pop_write_value(@control_handle)
      break if v.nil?
      print "control point write: #{hex(v)}\n"
      # 0x01 = "reset energy expended"; here it resets the simulated rate,
      # proving Ruby sees the bytes.
      if v.getbyte(0) == 1
        @bpm = 60
        print "  -> reset heart rate to 60\n"
      end
    end
  end

  # Heart Rate Measurement value: flags byte 0x00 (UINT8 BPM, no extras) + the rate.
  def hr_measurement(bpm)
    [0, bpm].pack("CC")
  end

  # Hex-encode a binary string for logging.
  def hex(s)
    out = ""
    i = 0
    while i < s.length
      out += sprintf("%02x", s.getbyte(i))
      i += 1
    end
    out
  end
end

$app = VirtualPeripheral.new
