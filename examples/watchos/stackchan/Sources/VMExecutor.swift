import Foundation

// Owns the persistent PicoRuby VM. mruby is single-threaded, so vm_open /
// vm_call / vm_close MUST all run on ONE thread.
//
// On watchOS that thread cannot be a plain DispatchQueue: the system default
// stack is very small there and mruby's initialization overflows it. A
// dedicated Thread lets us set stackSize explicitly. The serial workQueue is
// pinned to that thread, and every VM touch is funnelled through it — the
// SwiftUI layer only ever posts closures here and never calls vm_* directly.
final class VMExecutor {
    static let shared = VMExecutor()

    private var vmThread: VMThread?
    private var timer: DispatchSourceTimer?

    private init() {}

    // Open the VM with the bundled app.rb as boot source. Starts the periodic
    // BLE pump tick once open.
    func start(bootSource: String, onResult: @escaping (String) -> Void) {
        guard vmThread == nil else { return }
        let t = VMThread(bootSource: bootSource, executor: self, onReady: onResult)
        t.stackSize = 4 * 1024 * 1024   // 4MB stack for mruby init
        vmThread = t
        t.start()
    }

    // Post a vm_call(method, arg) onto the VM thread; deliver captured output on
    // the main queue.
    func call(_ method: String, _ arg: String, onResult: @escaping (String) -> Void) {
        guard let thread = vmThread else {
            DispatchQueue.main.async { onResult("(VM not ready)") }
            return
        }
        thread.enqueue {
            guard let vm = thread.vm else {
                // Deliver on main like the happy path below: callers mutate
                // SwiftUI @State in onResult and must never run off-main.
                DispatchQueue.main.async { onResult("(VM not ready)") }
                return
            }
            let out = method.withCString { m in
                arg.withCString { a in vm_call(vm, m, a) }
            }
            let result = out.map { String(cString: $0) } ?? ""
            if let out = out { free(out) }
            // Mirror every call's captured VM output to NSLog so the watch
            // console/syslog carries it; the watch screen is too small for an
            // Output pane, so this is where bring-up output is read.
            NSLog("[WatchStackchan] %@(%@) ->\n%@", method, arg, result)
            DispatchQueue.main.async { onResult(result) }
        }
    }

    // Periodic BLE event pump. tick() drains the Swift FIFO; cheap when not
    // connected. Runs on the same serial queue so it never races a vm_call.
    fileprivate func startTick() {
        guard let thread = vmThread else { return }
        let t = DispatchSource.makeTimerSource(queue: thread.workQueue)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
        t.setEventHandler {
            guard let vm = thread.vm else { return }
            let out = "tick".withCString { m in
                "".withCString { a in vm_call(vm, m, a) }
            }
            let result = out.map { String(cString: $0) } ?? ""
            if let out = out { free(out) }
            // tick output is not UI-worthy, but silently dropping it hides a
            // recurring per-tick exception; keep it visible in the log.
            if !result.isEmpty { NSLog("[WatchStackchan] tick ->\n%@", result) }
        }
        t.resume()
        self.timer = t
    }
}

// Dedicated thread that owns the mruby VM. All VM calls must run on workQueue,
// which is pinned to this thread.
final class VMThread: Thread {
    var vm: UnsafeMutableRawPointer?
    let workQueue: DispatchQueue

    private let bootSource: String
    private weak var executor: VMExecutor?
    private let onReady: (String) -> Void

    init(bootSource: String, executor: VMExecutor, onReady: @escaping (String) -> Void) {
        self.bootSource = bootSource
        self.executor = executor
        self.onReady = onReady
        self.workQueue = DispatchQueue(label: "com.bash0c7.watchstackchan.vm")
        super.init()
    }

    func enqueue(_ work: @escaping () -> Void) {
        workQueue.async(execute: work)
    }

    override func main() {
        NSLog("[WatchStackchan] VMThread starting (stack: 4MB)")
        guard let handle = bootSource.withCString({ vm_open($0) }) else {
            NSLog("[WatchStackchan] vm_open returned NULL (app.rb failed to load)")
            DispatchQueue.main.async { self.onReady("(VM failed to start)") }
            return
        }
        vm = handle
        NSLog("[WatchStackchan] VM opened")
        DispatchQueue.main.async { self.onReady("VM ready") }
        executor?.startTick()
        // Keep the thread alive so workQueue's work actually runs on it.
        RunLoop.current.run()
    }
}
