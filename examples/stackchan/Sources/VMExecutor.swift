import Foundation

// Owns the persistent PicoRuby VM. mruby is single-threaded, so vm_open /
// vm_call / vm_close MUST all run on ONE thread. This serial DispatchQueue is
// that thread: every VM touch is funnelled through `enqueue`, and the SwiftUI
// layer only ever posts closures here — it never calls vm_* directly.
final class VMExecutor {
    static let shared = VMExecutor()

    private let queue = DispatchQueue(label: "com.bash0c7.stackchan.vm")
    private var vm: UnsafeMutableRawPointer?
    private var timer: DispatchSourceTimer?

    private init() {}

    // Open the VM with the bundled app.rb as boot source. Posts onto the serial
    // queue and starts the periodic BLE pump tick once open.
    func start(bootSource: String, onResult: @escaping (String) -> Void) {
        queue.async {
            guard let handle = bootSource.withCString({ vm_open($0) }) else {
                NSLog("[Stackchan] vm_open returned NULL (app.rb failed to load)")
                onResult("(VM failed to start — app.rb did not load)")
                return
            }
            self.vm = handle
            NSLog("[Stackchan] VM opened")
            onResult("VM ready. Tap Connect to scan for Stack-chan.")
            self.startTick()
        }
    }

    // Post a vm_call(method, arg) onto the VM thread; deliver captured output on
    // the main queue.
    func call(_ method: String, _ arg: String, onResult: @escaping (String) -> Void) {
        queue.async {
            guard let vm = self.vm else {
                onResult("(VM not ready)")
                return
            }
            let out = method.withCString { m in
                arg.withCString { a in
                    vm_call(vm, m, a)
                }
            }
            let result = out.map { String(cString: $0) } ?? ""
            if let out = out { free(out) }
            DispatchQueue.main.async { onResult(result) }
        }
    }

    // Periodic BLE event pump. tick() drains the Swift FIFO; cheap when not
    // connected. Runs on the same serial queue so it never races vm_call.
    private func startTick() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
        t.setEventHandler { [weak self] in
            guard let self = self, let vm = self.vm else { return }
            let out = "tick".withCString { m in
                "".withCString { a in vm_call(vm, m, a) }
            }
            if let out = out { free(out) }
        }
        t.resume()
        self.timer = t
    }
}
