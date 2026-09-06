import SwiftUI

// Stack-chan watch controller. Each row enqueues a vm_call onto the single VM
// thread (VMExecutor); the UI itself never touches the VM.
//
// app.rb echoes every BLE frame it writes, so the captured output of a call is
// not just the status line. Each handler scans the output's LINES for its own
// prefix (face: / led: / head:) rather than matching the whole string.
struct ContentView: View {
    @State private var status: String = "Starting VM…"
    @State private var connected: Bool = false
    @State private var connectFailed: Bool = false
    @State private var busy: Bool = false
    @State private var faceState: String = "smile"
    @State private var ledColor: String? = nil
    @State private var sweeping: Bool = false

    var body: some View {
        List {
            Button(action: connect) {
                HStack {
                    Circle().fill(statusColor).frame(width: 14, height: 14)
                    Text(connected ? "Connected" : "Connect")
                }
            }
            .disabled(busy)

            Button(action: faceToggle) {
                HStack {
                    Text(faceState == "joy" ? "😆" : "😊").font(.title2)
                    Text("Face")
                }
            }

            Button(action: ledToggle) {
                HStack {
                    Circle().fill(ledSwatch).frame(width: 14, height: 14)
                    Text(ledColor == nil ? "LED off" : "LED \(ledColor!)")
                }
            }

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

    // MARK: - derived appearance

    private var statusColor: Color {
        if connected { return .green }
        if connectFailed && !busy { return .red }
        return .gray
    }

    private var ledSwatch: Color {
        // Must carry every entry in app.rb's Stackchan::LED_RANDOM_COLORS.
        // `nil` (LED off) stays gray; white means a colour is missing here.
        switch ledColor {
        case nil:       return .gray
        case "red":     return .red
        case "green":   return .green
        case "blue":    return .blue
        case "yellow":  return .yellow
        case "cyan":    return .cyan
        case "magenta": return Color(red: 1, green: 0, blue: 1)
        default:        return .white
        }
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
                self.faceState = face
                self.status = "face \(face)"
            } else {
                self.status = "face: no reply"
            }
        }
    }

    private func ledToggle() {
        VMExecutor.shared.call("led_toggle", "") { result in
            guard let led = self.statusLine(result, prefix: "led:") else {
                self.status = "led: no reply"
                return
            }
            if led == "off" {
                self.ledColor = nil
                self.status = "led off"
            } else if led.hasPrefix("on:") {
                let color = String(led.dropFirst("on:".count))
                self.ledColor = color
                self.status = "led \(color)"
            }
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
