# picoruby-ble Darwin port — device E2E

How to exercise the central/observer path (scan → connect → discover → read) over
a live radio from this harness. It needs a real BLE peripheral on a second device,
so a person runs it.

## Build

The runtime is `build-ble/host/bin/picoruby`. Build it with `rake build:ble`. To
build a port branch from a fork instead of upstream:

```
PICORUBY_REPO=<fork url> PICORUBY_REF=<branch> rake refresh build:ble
```

The central Mac needs Bluetooth on and Bluetooth permission granted to the
terminal (or the app launching the binary).

## A second device is required

A Mac acting as central cannot receive advertisements from a peripheral on the
same Mac. Run the peripheral on a separate device.

## Peripheral — pick one

### A. Swift fixture on a second Mac (deterministic)

`test/ble-darwin/test_peripheral.swift` exposes Device Information (0x180A) with a
readable Manufacturer Name (0x2A29) and a User Description descriptor (0x2901),
advertising the local name `PBLE-TEST`.

```
swift test/ble-darwin/test_peripheral.swift
# => [peripheral] advertising 'PBLE-TEST': service 180A / char 2A29 (read) / desc 2901
```

Leave it running. The characteristic value is `PBLE-TEST-MFR`, the descriptor
value `pble-demo-desc`.

### B. nRF Connect on iOS

nRF Connect can act as a peripheral. Labels vary by version; the flow is:

1. Configure a GATT server: add a service (e.g. Device Information 0x180A, or a
   custom one) with a characteristic that has the Read property and a value.
2. Create an advertiser packet with Complete Local Name `PBLE-TEST` and
   Connectable on.
3. Toggle the advertiser on and keep nRF Connect in the foreground; backgrounding
   drops the local name.

The characteristic value is arbitrary — a successful read is all that PASS needs.

## Run the central

```
build-ble/host/bin/picoruby test/ble-darwin/e2e_central.rb
```

The driver connects to a device advertising `TARGET_NAME` (default `PBLE-TEST`),
or to the strongest-RSSI device if none matches, then drives discover → read and
prints the tree. Set `TARGET_NAME = ""` to always pick the strongest. If the
peripheral does not advertise a name, place the device against the Mac so it is
the strongest signal.

Expected output (fixture):

```
[central] connecting to "PBLE-TEST" rssi=-40
[central] discovery done; state=TC_IDLE services=1
  svc uuid32=0x0A180000 1..N
    char uuid32=0x292A0000 vh=3 props=2 value="PBLE-TEST-MFR"
      desc uuid32=0x01290000 handle=4 value="pble-demo-desc"
E2E PASS: connect -> discover -> read characteristic value end-to-end
```

PASS = at least one service discovered and at least one characteristic value read.
uuid32 carries the 16-bit value in the high bytes because of the Base-UUID
convention (0x180A → 0x0A180000).

## ThreadSanitizer (optional)

To check the CoreBluetooth-queue / VM-thread boundary for data races, instrument
both sides: add `-fsanitize=thread` to the BLE build_config cc and linker flags,
add `--sanitize=thread` to picoruby-ble's Swift build, clear the port's
`ext/.build` cache, then `rake build:ble`. Run `e2e_central.rb` against an
advertising peripheral under `TSAN_OPTIONS="halt_on_error=0"`; connect → discover
→ read must actually run for the boundary to be exercised.

## Troubleshooting

- Many adv reports but the peripheral is never found: it is on the same Mac
  (loopback is not allowed). Use a separate device.
- No adv reports at all: check Bluetooth permission for the terminal/app under
  System Settings → Privacy & Security → Bluetooth.
- Discovers but stalls after connect: confirm the peripheral advertises
  connectable and the characteristic is readable. `e2e_central.rb` passes
  `debug: true` to print FSM transitions.
- Empty descriptor value: some descriptors carry no static value. A readable
  characteristic value reaching `:TC_IDLE` means the GATT path works.
