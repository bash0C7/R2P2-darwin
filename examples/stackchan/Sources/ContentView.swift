import SwiftUI

// Stack-chan controller. Each control enqueues a vm_call onto the single VM
// thread (VMExecutor); the UI itself never touches the VM. The captured stdout/
// stderr of every call is shown in the Output pane for bring-up.
struct ContentView: View {
    @State private var output: String = "Starting VM…"
    @State private var connected: Bool = false

    private let faces = ["neutral", "smile", "joy", "surprised", "sad", "angry"]
    private let ledColors = ["red", "green", "blue", "yellow", "white", "off"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Stack-chan Controller").font(.headline)

                HStack {
                    Button("Connect") { send("connect", "") }
                        .buttonStyle(.borderedProminent)
                    Text(connected ? "connected" : "not connected")
                        .font(.subheadline)
                        .foregroundStyle(connected ? .green : .secondary)
                }

                group("Face") {
                    flow(faces) { face in send("face", face) }
                }

                group("LED") {
                    flow(ledColors) { color in send("led", color) }
                }

                group("Head") {
                    HStack {
                        Button("Left")  { send("head", "left:40:400") }
                        Button("Up")    { send("head", "up:30:400") }
                        Button("Right") { send("head", "right:40:400") }
                    }
                    .buttonStyle(.bordered)
                }

                group("Torque") {
                    HStack {
                        Button("On")  { send("torque", "on") }
                        Button("Off") { send("torque", "off") }
                    }
                    .buttonStyle(.bordered)
                }

                Text("Output").font(.subheadline)
                Text(output.isEmpty ? "—" : output)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(Color(.secondarySystemBackground))
            }
            .padding()
        }
        .onAppear { boot() }
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).bold()
            content()
        }
    }

    @ViewBuilder
    private func flow(_ items: [String], _ action: @escaping (String) -> Void) -> some View {
        let columns = [GridItem(.adaptive(minimum: 88))]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                Button(item) { action(item) }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func boot() {
        guard let url = Bundle.main.url(forResource: "app", withExtension: "rb"),
              let src = try? String(contentsOf: url, encoding: .utf8) else {
            output = "(could not read bundled app.rb)"
            return
        }
        VMExecutor.shared.start(bootSource: src) { result in
            DispatchQueue.main.async { self.output = result }
        }
    }

    private func send(_ method: String, _ arg: String) {
        VMExecutor.shared.call(method, arg) { result in
            self.output = result.isEmpty ? "(no output)" : result
            if method == "connect" {
                self.connected = result.contains("Connected; RX value_handle bound")
            }
        }
    }
}
