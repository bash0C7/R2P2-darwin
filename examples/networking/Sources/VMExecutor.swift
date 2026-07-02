import Foundation

// Owns the persistent PicoRuby VM. mruby is single-threaded, so vm_open /
// vm_call / vm_close MUST all run on ONE thread. This serial DispatchQueue is
// that thread; the SwiftUI layer only posts onto it. app.rb defines $app =
// NetApp.new at boot; the FETCH button posts a `call("fetch")` which runs
// vm_call on the VM thread and returns app.rb's printed log lines.
//
// The blocking BSD-socket + mbedTLS handshake in picoruby-net runs here, on the
// background VM thread, so the main thread (UI) never blocks during the request.
final class VMExecutor {
    static let shared = VMExecutor()

    private let queue = DispatchQueue(label: "com.bash0c7.networking.vm")
    private var vm: UnsafeMutableRawPointer?
    private var onLog: ((String) -> Void)?

    private init() {}

    func start(bootSource: String, onLog: @escaping (String) -> Void) {
        self.onLog = onLog
        queue.async {
            guard let handle = bootSource.withCString({ vm_open($0) }) else {
                NSLog("[Networking] vm_open returned NULL (app.rb failed to load)")
                DispatchQueue.main.async { onLog("(VM failed to start — app.rb did not load)") }
                return
            }
            self.vm = handle
            NSLog("[Networking] VM opened")
            // On-device CLI verification: auto-run one fetch at boot so the TLS
            // round-trip result reaches the device console (readable via
            // `devicectl ... process launch --console`) without a manual tap.
            self.call("fetch")
        }
    }

    // Invoke `method` ("fetch") on $app, returning app.rb's captured stdout.
    func call(_ method: String) {
        queue.async {
            guard let vm = self.vm else { return }
            let out = method.withCString { m in "".withCString { a in vm_call(vm, m, a) } }
            let text = out.map { String(cString: $0) } ?? ""
            if let out = out { free(out) }
            if !text.isEmpty {
                NSLog("[Networking] %@", text)
                DispatchQueue.main.async { self.onLog?(text) }
            }
        }
    }
}
