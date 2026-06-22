import Foundation

// Owns the persistent PicoRuby VM. mruby is single-threaded, so vm_open /
// vm_call / vm_close MUST all run on ONE thread. This serial DispatchQueue is
// that thread; the SwiftUI layer only posts onto it. app.rb defines $app =
// TorchApp.new at boot; each button posts a `call("on"/"off")` which runs
// vm_call on the VM thread and returns app.rb's printed log line.
final class VMExecutor {
    static let shared = VMExecutor()

    private let queue = DispatchQueue(label: "com.bash0c7.torch.vm")
    private var vm: UnsafeMutableRawPointer?
    private var onLog: ((String) -> Void)?

    private init() {}

    func start(bootSource: String, onLog: @escaping (String) -> Void) {
        self.onLog = onLog
        queue.async {
            guard let handle = bootSource.withCString({ vm_open($0) }) else {
                NSLog("[Torch] vm_open returned NULL (app.rb failed to load)")
                DispatchQueue.main.async { onLog("(VM failed to start — app.rb did not load)") }
                return
            }
            self.vm = handle
            NSLog("[Torch] VM opened")
            // app.rb's readiness line printed during boot is not captured by
            // vm_open; the UI shows its own "VM ready" text. Button presses log.
        }
    }

    // Invoke `method` ("on"/"off") on $app, returning app.rb's captured stdout.
    func call(_ method: String) {
        queue.async {
            guard let vm = self.vm else { return }
            let out = method.withCString { m in "".withCString { a in vm_call(vm, m, a) } }
            let text = out.map { String(cString: $0) } ?? ""
            if let out = out { free(out) }
            if !text.isEmpty {
                NSLog("[Torch] %@", text)
                DispatchQueue.main.async { self.onLog?(text) }
            }
        }
    }
}
