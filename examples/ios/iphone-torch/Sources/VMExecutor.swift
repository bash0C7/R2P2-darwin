import Foundation

// Owns the PicoRuby VM. mruby is single-threaded, so the VM lives on this one
// serial DispatchQueue. app.rb is a plain top-level script (`loop do ... end`),
// so vm_open runs it to completion on that thread — until Stop.
//
// Stop never touches the VM from another thread: it only raises the gem's stop
// flag (TORCH_request_stop). The script's next `sleep` sees it, turns the torch
// off, and ends the loop with StopIteration; vm_open then returns here and the
// VM is closed on its own thread. Run again opens a fresh VM.
final class VMExecutor {
    static let shared = VMExecutor()

    private let queue = DispatchQueue(label: "com.bash0c7.torch.vm")
    private var running = false

    private init() {}

    func start(source: String, onFinished: @escaping () -> Void) {
        guard !running else { return }
        running = true
        queue.async {
            TORCH_clear_stop()
            NSLog("[Torch] VM starting: running app.rb")
            let handle = source.withCString { vm_open($0) }
            NSLog("[Torch] app.rb finished (vm_open returned %@)", handle == nil ? "NULL" : "handle")
            if let handle = handle { vm_close(handle) }
            self.running = false
            DispatchQueue.main.async { onFinished() }
        }
    }

    func stop() {
        TORCH_request_stop()
    }
}
