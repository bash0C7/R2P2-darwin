import SwiftUI

struct ContentView: View {
    @StateObject private var peripheral = PeripheralManager()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Virtual BLE Peripheral").font(.headline)
            Text("Advertising a PicoRuby-defined GATT profile. Connect from a BLE central; activity streams below.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(peripheral.log.isEmpty ? "—" : peripheral.log)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id("LOGEND")
                }
                .frame(maxHeight: .infinity)
                .border(.gray)
                .onChange(of: peripheral.log) { _, _ in
                    proxy.scrollTo("LOGEND", anchor: .bottom)
                }
            }
        }
        .padding()
        // The log is read-only, so the software keyboard never appears. These
        // are defensive: if any focusable control is ever added, a tap anywhere
        // or the keyboard "Done" button dismisses it so it can't cover the log.
        .contentShape(Rectangle())
        .onTapGesture { focused = false }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focused = false }
            }
        }
    }
}
