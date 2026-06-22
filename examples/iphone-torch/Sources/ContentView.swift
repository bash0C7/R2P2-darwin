import SwiftUI

// All torch behaviour lives in app.rb (driving AVCaptureDevice via the
// picoruby-iphone-torch Darwin port). This view boots the VM and maps the two
// buttons to vm_call("on") / vm_call("off"). Swift holds no torch logic.
struct ContentView: View {
    @State private var log: String = "Starting VM…"

    var body: some View {
        VStack(spacing: 16) {
            Text("iPhone Torch").font(.headline)
            Text("Ruby (PicoRuby) drives AVCaptureDevice through the picoruby-iphone-torch Darwin port.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 24) {
                Button("ON")  { VMExecutor.shared.call("on") }
                    .buttonStyle(.borderedProminent)
                Button("OFF") { VMExecutor.shared.call("off") }
                    .buttonStyle(.bordered)
            }
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
        log = "VM ready. Tap ON / OFF."
        VMExecutor.shared.start(bootSource: src) { line in
            if self.log.count > 8000 { self.log = String(self.log.suffix(6000)) }
            self.log += (self.log.isEmpty ? "" : "\n") + line
        }
    }
}
