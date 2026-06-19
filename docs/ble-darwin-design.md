# picoruby-ble Darwin port — design

The Darwin port drives CoreBluetooth (a high-level GATT API) and synthesizes the
BTstack-format event byte strings that `mrblib/ble_central.rb` decodes. The
decoder branches on `event_packet.getbyte(0)`; the port produces exactly those
bytes. Source of truth for behavior is the code under
`mrbgems/picoruby-ble/`; this document describes the contract that code implements.

## Scope

Central and observer only. The peripheral and broadcaster backends are no-op
stubs and the write path is a stub. The port does not synthesize 0xA3
included-service, 0xA6 long-value, or 0xA7/0xA8 notification/indication events,
because `ble_central.rb` has no decode body for them.

## Decode target is the decoder, not real BTstack

The vendored BTstack (1.6.2) serializes GATT events with the struct base four
bytes higher (service_id/connection_id inserted), but `ble_central.rb` reads the
older ABI offsets (struct base 4). So "real BTstack bytes equal what the decoder
expects" is false for this version. The port matches the decoder's offsets, given
below.

## Event byte layouts (9 events)

Handles are read with `byteslice(N,1)` (low byte), so GATT handles must be ≤ 255.
The only exception is the connection handle (`byteslice(4,2)`, 16-bit). Value and
descriptor lengths are also one byte (≤ 255). UUIDs are emitted as 128-bit,
LSB-first; the decoder's `uuid128_to_uuid32` does not recover the 16-bit alias
(0x180D → 0x0D180000), so comparisons use the full 128-bit UUID.

| event | code | byte layout |
|---|---|---|
| BTSTACK_EVENT_STATE (power-on) | 0x60 | `[0]=0x60, [2]=0x02 (HCI_STATE_WORKING)`. Emitted once after `centralManagerDidUpdateState == .poweredOn`. |
| GAP_EVENT_ADVERTISING_REPORT | 0xda | ≥ 14 bytes: `[0]=0xda, [2]=adv subcode, [3]=addr_type (0x01 random), [4..9]=6-byte synthetic BD_ADDR (LSB-first, each byte non-zero), [10]=(rssi_dBm+256)&0xff, [11]=AD-data len, [12..]=AD TLV ([len][type][value])`. Includes a complete-local-name (0x09) TLV so `name_include?` works. |
| LE_CONNECTION_COMPLETE | 0x3E (sub 0x01) | ≥ 6 bytes: `[0]=0x3E, [2]=0x01, [4..5]=conn_handle little-endian 16-bit` (e.g. 0x0040 → `40 00`). |
| LE disconnection | 0x3E (sub 0x05) | `[0]=0x3E, [2]=0x05`. Omitted on the read-only happy path. |
| GATT_EVENT_SERVICE_QUERY_RESULT | 0xA1 | ≥ 24 bytes: `[0]=0xA1, [4]=start_handle low, [6]=end_handle low, [8..23]=uuid128 LSB-first`. One per CBService, then a terminating 0xA0. end_handle is the real DFS subtree end. |
| GATT_EVENT_CHARACTERISTIC_QUERY_RESULT | 0xA2 | ≥ 28 bytes: `[0]=0xA2, [4]=start low, [6]=value_handle low, [8]=end low, [10]=properties low, [12..27]=uuid128 LSB-first`. One per characteristic, then a 0xA0. Properties map from CBCharacteristicProperties (READ=0x02, WRITE=0x08, WRITE_WO_RESP=0x04, NOTIFY=0x10, INDICATE=0x20). |
| GATT_EVENT_ALL_CHARACTERISTIC_DESCRIPTORS_QUERY_RESULT | 0xA4 | ≥ 22 bytes: `[0]=0xA4, [4]=descriptor handle low, [6..21]=uuid128 LSB-first`. UUID is at offset 6. One per descriptor, then a 0xA0. |
| GATT_EVENT_CHARACTERISTIC_VALUE_QUERY_RESULT | 0xA5 | `8+len` bytes: `[0]=0xA5, [4]=value_handle low, [6]=value len (≤255), [8..]=value`. Shared by characteristic value and descriptor value. |
| GATT_EVENT_QUERY_COMPLETE | 0xA0 | 2 bytes: `[0]=0xA0`. Exactly one after each phase batch; the decoder advances its FSM and shifts its worklist on it. A missing 0xA0 stalls the FSM (the decode loop has no timeout). |

## Threading

Two threads, with all mruby access confined to the VM thread.

- CoreBluetooth serial queue (`DispatchQueue(label: "pble.cb")`): every
  `CBCentralManagerDelegate` / `CBPeripheralDelegate` callback runs here. It does
  three things only: update the handle/address registry, build the BTstack-format
  `[UInt8]` packet, and push it onto a thread-safe FIFO. It never calls `mrb_*`,
  `BLE_push_event`, or `BLE_heartbeat`. mruby state is unreachable from this queue.
- The FIFO is `PicoBLEFifo` (Swift, NSLock). It holds raw byte packets only. It
  buffers the burst of results from a discovery phase, which the single-slot
  mailbox in shared `src/mruby/ble.c` would otherwise overwrite. An oversize
  packet (larger than the drain buffer) is dropped and logged so it cannot wedge
  the FIFO head and stall every later packet.
- The VM thread drains one packet per poll tick. The shared decoder's
  `mrb_pop_packet`, under `#ifdef PICORB_PLATFORM_DARWIN`, calls `pble_drain_one`
  to copy one packet out and feeds it to `BLE_push_event`. This is the only place
  `BLE_push_event` runs.
- `mrblib/ble.rb` is unchanged. Architecture-neutral Ruby carries no
  platform-specific code. The only shared-code touch is the
  `#ifdef PICORB_PLATFORM_DARWIN` drain hook in `src/mruby/ble.c`, matching the
  platform `#ifdef` convention other gems already use.
- Commands issued from the VM thread (connect, scan, discover, read) dispatch the
  actual CoreBluetooth calls onto `pble.cb` so all CoreBluetooth interaction stays
  on that one queue.

## Synthetic handle registry

CoreBluetooth objects live on the Swift side, so the registry does too
(lock-guarded).

- Connection handle: uint16 counter from 0x0040, incremented per connection.
- GATT handles: a single monotonic uint8 cursor (from 1), assigned by pre-order
  DFS, nesting discovery strictly — a service's characteristics and their
  descriptors are numbered before the next service's characteristics are
  discovered. A service's end handle is its DFS subtree end; a characteristic's
  end handle is its real value (the descriptor upper bound). This makes the
  decoder's containment checks hold by construction.
- Caps: entities past handle 255 are dropped and logged; values longer than 255
  bytes are truncated.
- Address: CoreBluetooth exposes `peripheral.identifier` (a UUID), not a BD_ADDR.
  The port hashes it to six bytes and ORs each byte with 0x01, because
  `BLE_central_gap_connect` reads the address with `mrb_get_args 'z'` (NUL
  terminated) and an interior 0x00 would truncate it. Both the wire order and the
  reversed order are mapped back to the CBPeripheral.

## Port files

| file | responsibility |
|---|---|
| `ports/darwin/ext/Sources/PicoBLEDarwin/PicoBLECentral.swift` | CBCentralManager + delegates on `pble.cb`; owns the registry; builds packets per the layouts above and pushes them to the FIFO; `@c` exports for init/power/scan/connect/discover/read. |
| `ports/darwin/ext/Sources/PicoBLEDarwin/PicoBLEFifo.swift` | Thread-safe byte-packet FIFO; `drainInto` copies one packet to the VM thread and drops oversize packets. |
| `ports/darwin/ble.c`, `ble_central.c` | port ABI (`BLE_*`, `BLE_central_*`) delegating to the Swift `@c` exports; `pble_drain_one` bridges the FIFO to the C side. |
| `ports/darwin/ble_peripheral.c`, `ble_common.h` | peripheral/broadcaster no-op stubs. |
| `src/mruby/ble.c` (shared) | the `#ifdef PICORB_PLATFORM_DARWIN` drain hook in `mrb_pop_packet`. |
| `mrbgem.rake` | on `build.darwin?`, defines `PICORB_PLATFORM_DARWIN`, builds the Swift backend (`PicoBLEDarwin`) and links the dylib, and compiles `ports/darwin/*.c`. |

The C export from Swift uses `@c` (SE-0495, swift-tools-version 6.3); `@_cdecl`
emits the C symbol but not a declaration in the generated `-Swift.h`.
