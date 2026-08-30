import SwiftUI

// The whole behaviour is app.rb, shown on screen so the audience can read the
// same code that is running. Run hands it to the PicoRuby VM
// (VMExecutor.start -> vm_open), which compiles it in-app and runs the loop.
// Stop raises the gem's stop flag; the loop ends at its next `sleep`.
// Swift holds no torch logic.
struct ContentView: View {
    @State private var source: String = ""
    @State private var running = false

    var body: some View {
        VStack(spacing: 16) {
            Text("iPhone Torch").font(.headline)
            Text("app.rb runs on PicoRuby; Torch drives AVCaptureDevice through the picoruby-iphone-torch Darwin port.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            ScrollView {
                Text(source.isEmpty ? "(could not read bundled app.rb)" : source)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 24) {
                Button("Run") {
                    running = true
                    VMExecutor.shared.start(source: source) { running = false }
                }
                .buttonStyle(.borderedProminent)
                .disabled(running || source.isEmpty)

                Button("Stop") { VMExecutor.shared.stop() }
                    .buttonStyle(.bordered)
                    .disabled(!running)
            }
            .font(.title2)
        }
        .padding()
        .onAppear { load() }
    }

    private func load() {
        guard let url = Bundle.main.url(forResource: "app", withExtension: "rb"),
              let src = try? String(contentsOf: url, encoding: .utf8) else { return }
        source = src
    }
}
