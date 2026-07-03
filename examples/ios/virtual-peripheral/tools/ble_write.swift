import CoreBluetooth
import Foundation

// Minimal macOS BLE central: scan for PBLE-TEST, connect, discover, write to the
// first writable characteristic, read any readable char, subscribe to notifies.
// Exits after the write completes or on a timeout.

let TARGET_NAME = ProcessInfo.processInfo.environment["TARGET_NAME"] ?? "PBLE-TEST"
let WRITE_HEX = ProcessInfo.processInfo.environment["WRITE_HEX"] ?? "01"
// Only look at the example's own GATT services. The phone ALSO exposes iOS system
// services (Continuity, Current Time…) over the same connection; restricting
// discovery to these UUIDs keeps the central from touching an Apple system
// characteristic by mistake. Heart Rate (0x180D) and Nordic UART (NUS) cover both
// app.rb profiles; override via APP_SERVICES="180d,6e400001-..." (comma-separated).
let APP_SERVICES: [CBUUID] = (ProcessInfo.processInfo.environment["APP_SERVICES"]
    ?? "180D,6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    .split(separator: ",").map { CBUUID(string: String($0).trimmingCharacters(in: .whitespaces)) }

func bytes(fromHex hex: String) -> [UInt8] {
    var out = [UInt8](); var i = hex.startIndex
    while i < hex.endIndex {
        let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
        if let b = UInt8(hex[i..<j], radix: 16) { out.append(b) }
        i = j
    }
    return out
}

final class Central: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var manager: CBCentralManager!
    var peripheral: CBPeripheral?
    var didWrite = false

    func start() { manager = CBCentralManager(delegate: self, queue: nil) }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            print("[central] powered on; scanning for \(TARGET_NAME)")
            c.scanForPeripherals(withServices: nil, options: nil)
        case .unauthorized:
            print("[central] UNAUTHORIZED — grant Bluetooth to the terminal in System Settings > Privacy & Security > Bluetooth")
            exit(2)
        case .poweredOff:
            print("[central] Bluetooth is powered off"); exit(3)
        default:
            print("[central] state = \(c.state.rawValue)")
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        if name == TARGET_NAME {
            print("[central] found \(name) (rssi \(RSSI)); connecting")
            c.stopScan()
            peripheral = p
            p.delegate = self
            c.connect(p, options: nil)
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        print("[central] connected; discovering services")
        p.discoverServices(APP_SERVICES)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] {
            print("[central] service \(s.uuid)")
            p.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            print("[central] char \(ch.uuid) props=\(ch.properties.rawValue)")
            if ch.properties.contains(.read) { p.readValue(for: ch) }
            if ch.properties.contains(.notify) { p.setNotifyValue(true, for: ch) }
            if !didWrite, ch.properties.contains(.write) || ch.properties.contains(.writeWithoutResponse) {
                let data = Data(bytes(fromHex: WRITE_HEX))
                let type: CBCharacteristicWriteType = ch.properties.contains(.write) ? .withResponse : .withoutResponse
                print("[central] WRITE \(WRITE_HEX) -> \(ch.uuid) (\(type == .withResponse ? "withResponse" : "withoutResponse"))")
                p.writeValue(data, for: ch, type: type)
                didWrite = true
                if type == .withoutResponse {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { print("[central] done"); exit(0) }
                }
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        if let e = error { print("[central] write error: \(e)") }
        else { print("[central] write ACKed by \(ch.uuid)") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { print("[central] done"); exit(0) }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        let hex = (ch.value ?? Data()).map { String(format: "%02x", $0) }.joined()
        print("[central] value \(ch.uuid) = \(hex)")
    }
}

let central = Central()
central.start()
DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
    print("[central] timeout — exiting"); exit(1)
}
RunLoop.main.run()
