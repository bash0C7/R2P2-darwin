import SwiftUI

// Stack-chan controller. Each control enqueues a vm_call onto the single VM
// thread (VMExecutor); the UI itself never touches the VM. The captured stdout/
// stderr of every call is shown in the Output pane for bring-up.
struct ContentView: View {
    @State private var output: String = "Starting VM…"
    @State private var connected: Bool = false
    @State private var busy: Bool = false
    @State private var connectFailed: Bool = false
    @State private var speakText: String = "ぼくスタックチャン、かわいいよ"
    @State private var speaking: Bool = false

    private let faces = ["neutral", "smile", "joy", "surprised", "sad", "angry"]
    private let ledColors = ["red", "green", "blue", "yellow", "white", "off"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    group("Face") {
                        flow(faces) { face in send("face", face) }
                    }

                    group("LED") {
                        flow(ledColors) { color in send("led", color) }
                    }

                    group("Head") {
                        VStack(spacing: 8) {
                            HStack {
                                Button("Left")   { send("head", "left:40:400") }
                                Button("Center") { send("head", "center") }
                                Button("Right")  { send("head", "right:40:400") }
                            }
                            HStack {
                                Button("Up") { send("head", "up:30:400") }
                            }
                        }
                        .buttonStyle(.glass)
                    }

                    group("Speech") {
                        VStack(spacing: 8) {
                            TextField("しゃべらせる言葉", text: $speakText)
                                .textFieldStyle(.roundedBorder)
                            Button("Speak") { speak() }
                                .buttonStyle(.glass)
                                .disabled(speaking || speakText.isEmpty)
                        }
                    }

                    group("Output") {
                        Text(output.isEmpty ? "—" : output)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding()
                            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
                    }
                }
                .padding()
            }
            .navigationTitle("Stack-chan")
            .navigationSubtitle(statusText)
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Button(connected ? "Connected" : "Connect") {
                        connect()
                    }
                    .buttonStyle(.glassProminent)
                    .tint(statusColor)
                    .disabled(busy)
                }
            }
        }
        .onAppear { boot() }
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).bold()
            content()
        }
    }

    @ViewBuilder
    private func flow(_ items: [String], _ action: @escaping (String) -> Void) -> some View {
        let columns = [GridItem(.adaptive(minimum: 96))]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                Button(item) { action(item) }
                    .buttonStyle(.glass)
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

    private var statusText: String {
        if busy { return "scanning…" }
        if connected { return "connected" }
        if connectFailed { return "connect failed — see Output" }
        return "not connected"
    }

    private var statusColor: Color {
        if connected { return .green }
        if connectFailed && !busy { return .red }
        return .accentColor
    }

    // Connect is long-running (the scan blocks the VM thread for up to 30 s):
    // reflect that immediately, and keep the button single-flight so a second
    // tap cannot queue another 30 s scan behind the first.
    private func connect() {
        busy = true
        connectFailed = false
        output = "Scanning for Stack-chan… (up to 30 s)"
        VMExecutor.shared.call("connect", "") { result in
            self.output = result.isEmpty ? "(no output)" : result
            self.connected = result.contains("Connected; RX value_handle bound")
            self.connectFailed = !self.connected
            self.busy = false
        }
    }

    private func send(_ method: String, _ arg: String) {
        VMExecutor.shared.call(method, arg) { result in
            self.output = result.isEmpty ? "(no output)" : result
        }
    }

    // Speak is long-running (synthesis, then the VM thread streams audio and
    // sits out the device's drain window): single-flight like connect.
    // Serial-queue ordering makes subtitle land before the audio frames.
    private func speak() {
        speaking = true
        output = "Synthesizing…"
        let text = speakText
        send("subtitle", text)
        SpeechSynth.shared.synthesize(text: text) { hex in
            guard let hex else {
                self.output = "speech synthesis failed"
                self.speaking = false
                return
            }
            VMExecutor.shared.call("speak_audio", hex) { result in
                self.output = result.isEmpty ? "(no output)" : result
                self.speaking = false
            }
        }
    }
}
