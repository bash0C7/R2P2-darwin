import SwiftUI

// All networking behaviour lives in app.rb (driving picoruby-net's mbedTLS HTTP/TLS
// stack). This view boots the VM and maps the FETCH button to vm_call("fetch").
// Swift holds no networking logic.
struct ContentView: View {
    @State private var log: String = "Starting VM…"

    var body: some View {
        VStack(spacing: 16) {
            Text("PicoRuby Networking").font(.headline)
            Text("Ruby (PicoRuby) runs an HTTPS GET through picoruby-net: a raw BSD socket plus an mbedTLS handshake seeded by the SecRandomCopyBytes Darwin port.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("FETCH") { VMExecutor.shared.call("fetch") }
                .buttonStyle(.borderedProminent)
                .font(.title2)

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
        log = "VM ready. Tap FETCH."
        VMExecutor.shared.start(bootSource: src) { line in
            if self.log.count > 8000 { self.log = String(self.log.suffix(6000)) }
            self.log += (self.log.isEmpty ? "" : "\n") + line
        }
    }
}
