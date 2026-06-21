import SwiftUI

struct ContentView: View {
    @State private var source: String = "puts \"hello #{1 + 2}\""
    @State private var output: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PicoRuby Runner").font(.headline)
            TextEditor(text: $source)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 140)
                .border(.gray)
            Button("Run") { run() }
                .buttonStyle(.borderedProminent)
            Text("Output").font(.subheadline)
            ScrollView {
                Text(output.isEmpty ? "—" : output)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .border(.gray)
            Spacer()
        }
        .padding()
        .onAppear { run() }
    }

    private func run() {
        // Run picoruby on a background thread to avoid blocking SwiftUI layout.
        DispatchQueue.global(qos: .userInitiated).async {
            guard let cstr = repl_eval(self.source) else {
                NSLog("[PicoRubyRunner] eval returned NULL")
                DispatchQueue.main.async {
                    self.output = "(VM failed to start)"
                }
                return
            }
            let result = String(cString: cstr)
            free(cstr)
            // NSLog goes to the unified log (visible via simctl spawn log stream)
            NSLog("[PicoRubyRunner] output:\n%@", result)
            print("[PicoRubyRunner] output:\n\(result)")
            DispatchQueue.main.async {
                self.output = result
            }
        }
    }
}
