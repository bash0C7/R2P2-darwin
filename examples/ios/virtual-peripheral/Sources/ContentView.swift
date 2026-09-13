import SwiftUI

// Read-only view over the peripheral's activity. All behavior lives in app.rb;
// this view boots the VM and appends whatever each tick prints. Swift holds no
// BLE logic — the GATT server is the picoruby-ble Darwin port, driven by Ruby.
struct ContentView: View {
    @State private var log: String = "Starting VM…"

    var body: some View {
        NavigationStack {
            LogPane(text: log)
                .navigationTitle("Virtual BLE Peripheral")
                .navigationSubtitle("PicoRuby GATT profile — connect from a central")
        }
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
