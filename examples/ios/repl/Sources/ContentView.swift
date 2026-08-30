import SwiftUI

struct ContentView: View {
    @State private var source: String = "puts \"hello #{1 + 2}\""
    @State private var output: String = ""
    @FocusState private var editorFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $source)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 140)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
                    .padding([.horizontal, .top])
                    .focused($editorFocused)

                ScrollView {
                    Text(output.isEmpty ? "—" : output)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding()
                }
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
                .padding()
            }
            .navigationTitle("PicoRuby Runner")
            // Tap outside the editor to dismiss the keyboard so the output is visible.
            .contentShape(Rectangle())
            .onTapGesture { editorFocused = false }
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Button("Run") { run() }
                        .buttonStyle(.glassProminent)
                }
                // A Done button above the keyboard for explicit dismissal.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { editorFocused = false }
                }
            }
        }
        .onAppear { run() }
    }

    private func run() {
        // Dismiss the keyboard so the output area is visible after running.
        editorFocused = false
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
