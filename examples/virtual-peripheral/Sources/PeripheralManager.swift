import CoreBluetooth
import Foundation

// The CoreBluetooth radio. It holds NO device logic: at power-on it loads the
// bundled app.rb into the VM, asks the VM for the GATT profile, builds the
// service tree, advertises, and forwards every central event to the VM —
// applying whatever the VM prints (a value to return, a frame to notify). All
// behavior lives in app.rb. Keyed by each characteristic's canonical lowercase
// UUID string, which is also how app.rb names them.
final class PeripheralManager: NSObject, ObservableObject, CBPeripheralManagerDelegate {
    @Published var log: String = ""

    private var manager: CBPeripheralManager!
    private var deviceName = "PBLE-TEST"
    private var chars: [String: CBMutableCharacteristic] = [:]
    private var timer: Timer?

    override init() {
        super.init()
        let boot = Self.loadAppRb()
        VMExecutor.shared.start(bootSource: boot) { [weak self] msg in
            self?.append(msg)
        }
        manager = CBPeripheralManager(delegate: self, queue: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pump()
        }
    }

    private static func loadAppRb() -> String {
        guard let url = Bundle.main.url(forResource: "app", withExtension: "rb"),
              let s = try? String(contentsOf: url, encoding: .utf8) else {
            NSLog("[VirtualPeripheral] app.rb not found in bundle")
            return "$app = Object.new"
        }
        return s
    }

    private func append(_ line: String) {
        guard !line.isEmpty else { return }
        DispatchQueue.main.async {
            self.log += (self.log.isEmpty ? "" : "\n") + line
        }
    }

    // "<value>|<log>" -> (value, log). If no "|", the whole string is the value.
    private func split(_ s: String) -> (String, String) {
        guard let bar = s.firstIndex(of: "|") else { return (s, "") }
        return (String(s[..<bar]), String(s[s.index(after: bar)...]))
    }

    // MARK: CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            append("BLE powered on; building profile")
            buildAndAdvertise()
        case .poweredOff:    append("BLE powered off")
        case .unauthorized:  append("BLE unauthorized — grant Bluetooth permission in Settings")
        case .unsupported:   append("BLE unsupported here (the Simulator has no Bluetooth radio)")
        default:             append("BLE state changed: \(peripheral.state.rawValue)")
        }
    }

    private func buildAndAdvertise() {
        guard let spec = VMExecutor.shared.callSync("profile", "") else {
            append("(VM profile unavailable)")
            return
        }
        var services: [CBMutableService] = []
        var current: CBMutableService?
        var currentChars: [CBCharacteristic] = []
        func flush() {
            if let svc = current { svc.characteristics = currentChars; services.append(svc) }
        }
        for raw in spec.split(separator: "\n") {
            let line = String(raw)
            if line.hasPrefix("NAME ") {
                deviceName = String(line.dropFirst(5))
            } else if line.hasPrefix("SERVICE ") {
                flush()
                current = CBMutableService(type: CBUUID(string: String(line.dropFirst(8))), primary: true)
                currentChars = []
            } else if line.hasPrefix("CHAR ") {
                let parts = line.dropFirst(5).split(separator: " ")
                guard parts.count == 2 else { continue }
                let uuid = String(parts[0])
                let props = String(parts[1])
                var p: CBCharacteristicProperties = []
                var a: CBAttributePermissions = []
                if props.contains("r") { p.insert(.read);   a.insert(.readable) }
                if props.contains("w") { p.insert(.write);  a.insert(.writeable) }
                if props.contains("n") { p.insert(.notify) }
                let cbuuid = CBUUID(string: uuid)
                let ch = CBMutableCharacteristic(type: cbuuid, properties: p, value: nil, permissions: a)
                chars[cbuuid.uuidString.lowercased()] = ch
                currentChars.append(ch)
            }
        }
        flush()
        for svc in services { manager.add(svc) }
        manager.startAdvertising([
            CBAdvertisementDataLocalNameKey: deviceName,
            CBAdvertisementDataServiceUUIDsKey: services.map { $0.uuid },
        ])
        append("Advertising as \"\(deviceName)\" with \(services.count) service(s)")
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        let uuid = request.characteristic.uuid.uuidString.lowercased()
        guard let resp = VMExecutor.shared.callSync("on_read", uuid) else {
            p.respond(to: request, withResult: .unlikelyError)
            return
        }
        let (hex, log) = split(resp)
        request.value = Data(hexString: hex)
        p.respond(to: request, withResult: .success)
        append(log)
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            let uuid = request.characteristic.uuid.uuidString.lowercased()
            let hex = (request.value ?? Data()).hexString
            guard let resp = VMExecutor.shared.callSync("on_write", "\(uuid)|\(hex)") else { continue }
            let (head, log) = split(resp)
            append(log)
            if !head.isEmpty, let colon = head.firstIndex(of: ":") {
                notify(uuidString: String(head[..<colon]),
                       hex: String(head[head.index(after: colon)...]))
            }
        }
        if let first = requests.first { p.respond(to: first, withResult: .success) }
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        if let log = VMExecutor.shared.callSync("on_subscribe", characteristic.uuid.uuidString.lowercased()) {
            append(log)
        }
    }

    func peripheralManager(_ p: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        if let log = VMExecutor.shared.callSync("on_unsubscribe", characteristic.uuid.uuidString.lowercased()) {
            append(log)
        }
    }

    // MARK: tick + notify

    private func pump() {
        guard let out = VMExecutor.shared.callSync("tick", ""), !out.isEmpty else { return }
        for raw in out.split(separator: "\n") {
            let (head, log) = split(String(raw))
            if let colon = head.firstIndex(of: ":") {
                notify(uuidString: String(head[..<colon]),
                       hex: String(head[head.index(after: colon)...]))
            }
            append(log)
        }
    }

    private func notify(uuidString: String, hex: String) {
        let key = CBUUID(string: uuidString).uuidString.lowercased()
        guard let ch = chars[key] else { return }
        manager.updateValue(Data(hexString: hex), for: ch, onSubscribedCentrals: nil)
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init(hexString: String) {
        var data = Data()
        var i = hexString.startIndex
        while i < hexString.endIndex {
            let j = hexString.index(i, offsetBy: 2, limitedBy: hexString.endIndex) ?? hexString.endIndex
            if let b = UInt8(hexString[i..<j], radix: 16) { data.append(b) }
            i = j
        }
        self = data
    }
}
