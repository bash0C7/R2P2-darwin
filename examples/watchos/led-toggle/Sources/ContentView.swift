import SwiftUI

struct ContentView: View {
    @State private var color = "red"

    var body: some View {
        Text(color == "red" ? "🔴" : "🔵")
            .font(.system(size: 80))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onTapGesture {
                VMExecutor.shared.toggle()
            }
            .onAppear {
                boot()
            }
    }

    private func boot() {
        guard let url = Bundle.main.url(forResource: "app", withExtension: "rb"),
              let src = try? String(contentsOf: url, encoding: .utf8) else {
            NSLog("[WatchLEDToggle] could not read app.rb")
            return
        }
        VMExecutor.shared.start(bootSource: src) { c in
            color = c
        }
    }
}
