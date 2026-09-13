import SwiftUI

// All tilt-to-sound behaviour lives in app.rb (driving CMDeviceMotion via
// picoruby-iphone-motion and AVAudioEngine via picoruby-iphone-synth). This
// view only boots the VM and displays the log lines app.rb prints each tick.
// Swift holds no music-mapping logic -- there is no start/stop button because
// the tick timer (and therefore the synth) runs continuously once booted.
struct ContentView: View {
    @State private var log: String = "Starting VM…"
    @State private var pitch: Double = 0
    @State private var roll: Double = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 16) {
                    Gauge(value: pitch, in: -30...30) {
                        Text("Pitch (前後)")
                    } currentValueLabel: {
                        Text(String(format: "%.0f°", pitch))
                    }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(.blue)

                    Gauge(value: roll, in: -45...45) {
                        Text("Roll (左右)")
                    } currentValueLabel: {
                        Text(String(format: "%.0f°", roll))
                    }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(.orange)
                }
                .padding()
                .glassEffect(in: .rect(cornerRadius: 20))
                .padding([.horizontal, .top])

                LogPane(text: log)
            }
            .navigationTitle("Tilt Synth")
            .navigationSubtitle("Tilt: pitch · Roll: FM depth")
        }
        .onAppear { boot() }
    }

    private func boot() {
        guard let url = Bundle.main.url(forResource: "app", withExtension: "rb"),
              let src = try? String(contentsOf: url, encoding: .utf8) else {
            log = "(could not read bundled app.rb)"
            return
        }
        log = "VM ready. Tilt the phone."
        VMExecutor.shared.start(bootSource: src) { line in
            if self.log.count > 8000 { self.log = String(self.log.suffix(6000)) }
            self.log += (self.log.isEmpty ? "" : "\n") + line
            self.updateMeters(from: line)
        }
    }

    // Each tick line looks like "pitch=<v> roll=<v> note=<v> depth=<v>";
    // pull the last line's pitch/roll straight out of the log text app.rb
    // already prints, rather than adding a second reporting channel.
    private func updateMeters(from line: String) {
        guard let lastLine = line.split(separator: "\n").last else { return }
        for field in lastLine.split(separator: " ") {
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let value = Double(parts[1]) else { continue }
            if parts[0] == "pitch" { pitch = value }
            if parts[0] == "roll" { roll = value }
        }
    }
}

// Monospaced, auto-scrolling log in a rounded content pane.
struct LogPane: View {
    let text: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? "—" : text)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
                    .id("LOGEND")
            }
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
            .padding()
            .onChange(of: text) { _, _ in proxy.scrollTo("LOGEND", anchor: .bottom) }
        }
    }
}
