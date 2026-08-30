import SwiftUI

// The whole behaviour is app.rb, shown on screen so the audience can read the
// same code that is running. Run hands it to the PicoRuby VM
// (VMExecutor.start -> vm_open), which compiles it in-app and runs the loop.
// Stop raises the gem's stop flag; the loop ends at its next `sleep`.
// Swift holds no torch logic. Controls live in the bottom toolbar (Liquid
// Glass); the code pane is plain content underneath.
struct ContentView: View {
    @State private var source: String = ""
    @State private var running = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(source.isEmpty ? "(could not read bundled app.rb)" : source)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
                    .padding()
            }
            .navigationTitle("iPhone Torch")
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Button("Run") {
                        running = true
                        VMExecutor.shared.start(source: source) { running = false }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(running || source.isEmpty)
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Button("Stop") { VMExecutor.shared.stop() }
                        .buttonStyle(.glass)
                        .disabled(!running)
                }
            }
        }
        .onAppear { load() }
    }

    private func load() {
        guard let url = Bundle.main.url(forResource: "app", withExtension: "rb"),
              let src = try? String(contentsOf: url, encoding: .utf8) else { return }
        source = src
    }
}
