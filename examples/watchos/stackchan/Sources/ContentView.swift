import SwiftUI

// Stack-chan watch controller. Each row enqueues a vm_call onto the single VM
// thread (VMExecutor); the UI itself never touches the VM.
//
// app.rb echoes every BLE frame it writes, so the captured output of a call is
// not just the status line. Each handler scans the output's LINES for its own
// prefix (face: / led: / head:) rather than matching the whole string.
//
// Every button is labelled with the action its tap performs. Current state —
// connected or not, which face is showing, whether the LED show is running —
// lives in the status line at the bottom, never on a button.
struct ContentView: View {
    @State private var status: String = "Starting VM…"
    @State private var connected: Bool = false
    @State private var connectFailed: Bool = false
    @State private var busy: Bool = false
    @State private var showingLED: Bool = false
    @State private var sweeping: Bool = false

    var body: some View {
        List {
            Button(action: connect) {
                HStack {
                    Text("🔗").font(.title2)
                    Text("つなぐ")
                }
            }
            .disabled(busy)

            Button(action: faceToggle) {
                HStack {
                    Text("😄").font(.title2)
                    Text("顔をかえる")
                }
            }

            Button(action: ledShow) {
                HStack {
                    Text("💡").font(.title2)
                    Text("LEDを光らせる")
                }
            }
            .disabled(showingLED)

            Button(action: headSweep) {
                HStack {
                    Text("↻").font(.title2)
                    Text("ぐるっと")
                }
            }
            .disabled(sweeping)

            Text(status)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .onAppear { boot() }
    }


    // MARK: - VM plumbing

    private func boot() {
        guard let url = Bundle.main.url(forResource: "app", withExtension: "rb"),
              let src = try? String(contentsOf: url, encoding: .utf8) else {
            status = "could not read app.rb"
            return
        }
        VMExecutor.shared.start(bootSource: src) { result in
            self.status = result
        }
    }

    // The last line of `output` that starts with `prefix`, minus the prefix.
    private func statusLine(_ output: String, prefix: String) -> String? {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .last(where: { $0.hasPrefix(prefix) })
            .map { String($0.dropFirst(prefix.count)) }
    }

    // MARK: - actions

    // Connect blocks the VM thread for the scan's duration (SCAN_TIMEOUT_MS in
    // app.rb, 10 s): reflect that immediately and keep the button single-flight
    // so a second tap cannot queue another scan behind the first.
    private func connect() {
        busy = true
        connectFailed = false
        status = "Scanning…"
        VMExecutor.shared.call("connect", "") { result in
            self.connected = result.contains("Connected; RX value_handle bound")
            self.connectFailed = !self.connected
            self.status = self.connected ? "connected" : "not found"
            self.busy = false
        }
    }

    private func faceToggle() {
        VMExecutor.shared.call("face_toggle", "") { result in
            if let face = self.statusLine(result, prefix: "face:") {
                self.status = "face \(face)"
            } else {
                self.status = "face: no reply"
            }
        }
    }

    // led_show cycles six colours at LED_STEP_MS and then switches the LED off
    // itself, blocking the VM thread for about 3 s: single-flight like headSweep.
    private func ledShow() {
        showingLED = true
        status = "led…"
        VMExecutor.shared.call("led_show", "") { result in
            self.status = self.statusLine(result, prefix: "led:") != nil
                ? "led done" : "led: no reply"
            self.showingLED = false
        }
    }

    // head_sweep blocks the VM thread for ~1.8 s: single-flight like connect.
    private func headSweep() {
        sweeping = true
        status = "sweeping…"
        VMExecutor.shared.call("head_sweep", "") { result in
            self.status = self.statusLine(result, prefix: "head:") != nil
                ? "swept" : "sweep: no reply"
            self.sweeping = false
        }
    }
}
