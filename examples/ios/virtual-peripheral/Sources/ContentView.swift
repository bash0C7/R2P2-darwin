import SwiftUI

// Read-only view over the peripheral's activity. All behavior lives in app.rb;
// this view boots the VM and appends whatever each tick prints. Swift holds no
// BLE logic — the GATT server is the picoruby-ble Darwin port, driven by Ruby.
struct ContentView: View {
    @State private var log: String = "Starting VM…"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Virtual BLE Peripheral").font(.headline)
            Text("A PicoRuby-defined GATT profile, served by the picoruby-ble Darwin port. Connect from a BLE central; activity streams below.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(log.isEmpty ? "—" : log)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("LOGEND")
                }
                .frame(maxHeight: .infinity)
                .border(.gray)
                .onChange(of: log) { _, _ in proxy.scrollTo("LOGEND", anchor: .bottom) }
            }
        }
        .padding()
        .onAppear { boot() }
    }

    private func boot() {
        guard let url = Bundle.main.url(forResource: "app", withExtension: "rb"),
              let src = try? String(contentsOf: url, encoding: .utf8) else {
            log = "(could not read bundled app.rb)"
            return
        }
        log = ""
        VMExecutor.shared.start(bootSource: src) { line in
            if self.log.count > 8000 { self.log = String(self.log.suffix(6000)) }
            self.log += (self.log.isEmpty ? "" : "\n") + line
        }
    }
}
