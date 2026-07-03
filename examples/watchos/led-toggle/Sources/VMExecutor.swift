import Foundation

final class VMExecutor {
    static let shared = VMExecutor()

    // Use a dedicated Thread with a larger stack to avoid watchOS stack overflow
    // during mruby VM initialization. DispatchQueue uses the system default
    // (which is very small on watchOS), while Thread.stackSize can be set explicitly.
    private var vmThread: VMThread?
    private var timer: DispatchSourceTimer?
    var onColorChange: ((String) -> Void)?

    private init() {}

    func start(bootSource: String, onColor: @escaping (String) -> Void) {
        self.onColorChange = onColor
        guard vmThread == nil else { return }
        let t = VMThread(bootSource: bootSource, executor: self)
        t.stackSize = 4 * 1024 * 1024  // 4MB stack for mruby init
        vmThread = t
        t.start()
    }

    func toggle() {
        vmThread?.enqueue {
            guard let vm = self.vmThread?.vm else { return }
            let out = "toggle".withCString { m in
                "".withCString { a in vm_call(vm, m, a) }
            }
            let color = out.map {
                String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? ""
            if let o = out { free(o) }
            guard !color.isEmpty else { return }
            DispatchQueue.main.async { self.onColorChange?(color) }
        }
    }

    func vmOpened() {
        let t = DispatchSource.makeTimerSource(queue: vmThread!.workQueue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in
            guard let self = self, let vm = self.vmThread?.vm else { return }
            let out = "tick".withCString { m in
                "".withCString { a in vm_call(vm, m, a) }
            }
            let color = out.map {
                String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? ""
            if let o = out { free(o) }
            guard color == "red" || color == "blue" else { return }
            DispatchQueue.main.async { self.onColorChange?(color) }
        }
        t.resume()
        self.timer = t
    }
}

// Dedicated thread that owns the mruby VM. All VM calls must run on workQueue
// which is pinned to this thread.
final class VMThread: Thread {
    var vm: UnsafeMutableRawPointer?
    let workQueue: DispatchQueue
    private let bootSource: String
    private weak var executor: VMExecutor?

    init(bootSource: String, executor: VMExecutor) {
        self.bootSource = bootSource
        self.executor = executor
        self.workQueue = DispatchQueue(label: "com.bash0c7.watch.vm")
        super.init()
    }

    func enqueue(_ work: @escaping () -> Void) {
        workQueue.async(execute: work)
    }

    override func main() {
        NSLog("[WatchLEDToggle] VMThread starting (stack: 4MB)")
        guard let handle = bootSource.withCString({ vm_open($0) }) else {
            NSLog("[WatchLEDToggle] vm_open returned NULL")
            return
        }
        vm = handle
        NSLog("[WatchLEDToggle] VM opened")
        executor?.vmOpened()
        // Keep thread alive for the workQueue
        RunLoop.current.run()
    }
}
