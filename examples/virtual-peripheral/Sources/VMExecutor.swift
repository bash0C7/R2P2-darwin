import Foundation

// Owns the persistent PicoRuby VM. mruby is single-threaded, so vm_open /
// vm_call / vm_close MUST all run on ONE thread. This serial DispatchQueue is
// that thread. The CoreBluetooth delegate calls `callSync` (it must answer a
// central synchronously); the timer calls it for ticks. Because vm_open is
// enqueued first, every later callSync (a queue.sync) runs after the VM is open.
final class VMExecutor {
    static let shared = VMExecutor()

    private let queue = DispatchQueue(label: "com.bash0c7.vperiph.vm")
    private var vm: UnsafeMutableRawPointer?

    private init() {}

    // Open the VM with the bundled app.rb as boot source.
    func start(bootSource: String, onResult: @escaping (String) -> Void) {
        queue.async {
            guard let handle = bootSource.withCString({ vm_open($0) }) else {
                NSLog("[VirtualPeripheral] vm_open returned NULL (app.rb failed to load)")
                onResult("(VM failed to start — app.rb did not load)")
                return
            }
            self.vm = handle
            NSLog("[VirtualPeripheral] VM opened")
            onResult("VM ready")
        }
    }

    // Synchronously invoke vm_call(method, arg) on the VM thread and return its
    // captured stdout. Returns nil if the VM is not open yet.
    func callSync(_ method: String, _ arg: String) -> String? {
        queue.sync {
            guard let vm = self.vm else { return nil }
            let out = method.withCString { m in
                arg.withCString { a in vm_call(vm, m, a) }
            }
            let result = out.map { String(cString: $0) }
            if let out = out { free(out) }
            return result
        }
    }
}
