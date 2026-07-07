import Foundation

// Owns the persistent PicoRuby VM. mruby is single-threaded, so vm_open /
// vm_call / vm_close MUST all run on ONE thread. This serial DispatchQueue is
// that thread; the SwiftUI layer only posts onto it. The tilt-to-sound
// behaviour is entirely in app.rb: vm_open boots it ($app = TiltSynthApp.new,
// which starts the Synth), then a periodic `tick` reads Motion and drives
// Synth. Neither CoreMotion nor AVAudioEngine touch mruby directly -- only
// this VM thread calls vm_call.
final class VMExecutor {
    static let shared = VMExecutor()

    private let queue = DispatchQueue(label: "com.bash0c7.tiltsynth.vm")
    private var vm: UnsafeMutableRawPointer?
    private var timer: DispatchSourceTimer?
    private var onLog: ((String) -> Void)?

    private init() {}

    func start(bootSource: String, onLog: @escaping (String) -> Void) {
        self.onLog = onLog
        queue.async {
            guard let handle = bootSource.withCString({ vm_open($0) }) else {
                NSLog("[TiltSynth] vm_open returned NULL (app.rb failed to load)")
                DispatchQueue.main.async { onLog("(VM failed to start — app.rb did not load)") }
                return
            }
            self.vm = handle
            NSLog("[TiltSynth] VM opened")
            self.startTick()
        }
    }

    // 20Hz poll: vm_call("tick") runs one iteration of app.rb's tilt-to-sound
    // mapping and returns any new log lines (captured stdout).
    private func startTick() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.05, repeating: 0.05)
        t.setEventHandler { [weak self] in
            guard let self = self, let vm = self.vm else { return }
            let out = "tick".withCString { m in "".withCString { a in vm_call(vm, m, a) } }
            let text = out.map { String(cString: $0) } ?? ""
            if let out = out { free(out) }
            if !text.isEmpty {
                NSLog("[TiltSynth] %@", text)
                DispatchQueue.main.async { self.onLog?(text) }
            }
        }
        t.resume()
        self.timer = t
    }
}
