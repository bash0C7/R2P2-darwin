import Foundation

// Owns the persistent PicoRuby VM. mruby is single-threaded, so vm_open /
// vm_call / vm_close MUST all run on ONE thread. This serial DispatchQueue is
// that thread; the SwiftUI layer only posts onto it. The peripheral's whole
// behavior is in app.rb: vm_open boots it (building the GATT DB — the radio
// stays off until the first tick window powers it on), then a periodic `tick`
// runs one bounded BLE#start event-loop window, the canonical picoruby-ble
// loop. The CoreBluetooth backend (PicoBLEDarwin) is reconciled with mruby
// inside that window (pble_drain_one -> the port's pump), so the VM thread is
// the only one that touches mruby.
final class VMExecutor {
    static let shared = VMExecutor()

    private let queue = DispatchQueue(label: "com.bash0c7.vperiph.vm")
    private var vm: UnsafeMutableRawPointer?
    private var timer: DispatchSourceTimer?
    private var onLog: ((String) -> Void)?

    private init() {}

    // Open the VM with the bundled app.rb as boot source, then start the poll tick.
    func start(bootSource: String, onLog: @escaping (String) -> Void) {
        self.onLog = onLog
        queue.async {
            guard let handle = bootSource.withCString({ vm_open($0) }) else {
                NSLog("[VirtualPeripheral] vm_open returned NULL (app.rb failed to load)")
                DispatchQueue.main.async { onLog("(VM failed to start — app.rb did not load)") }
                return
            }
            self.vm = handle
            NSLog("[VirtualPeripheral] VM opened")
            self.startTick()
        }
    }

    // Periodic drive: vm_call("tick") runs one bounded BLE#start window
    // (app.rb's WINDOW_MS) and returns its log lines (captured stdout). Each
    // window outlasts the 100 ms timer period, so pending fires coalesce and
    // the windows run back-to-back: the VM sits inside the event loop for
    // ~all wall-clock time, and this timer merely restarts the next window.
    private func startTick() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in
            guard let self = self, let vm = self.vm else { return }
            let out = "tick".withCString { m in "".withCString { a in vm_call(vm, m, a) } }
            let text = out.map { String(cString: $0) } ?? ""
            if let out = out { free(out) }
            if !text.isEmpty {
                NSLog("[VirtualPeripheral] %@", text)
                DispatchQueue.main.async { self.onLog?(text) }
            }
        }
        t.resume()
        self.timer = t
    }
}
