import SwiftUI

struct ContentView: View {
    // Seed: AOT vs interpreter benchmark. `bench_tick` is the native (suppify/
    // spinel AOT) top-level method registered by the picoruby-bench_tick mrbgem;
    // `bench_tick_rb` is the identical kernel written in plain Ruby (interpreted
    // baseline). Same inputs must give the same checksum (parity), then we time
    // both with total work held constant while sweeping the per-call scope n, so
    // the native call boundary cost amortizes as n grows.
    @State private var source: String = """
    def bench_tick_rb(seed, n)
      s = seed & 0x7FFF
      y1 = 0; y2 = 0; ema = 0; sum = 0; i = 0
      while i < n
        s = (s * 75 + 74) & 0x7FFF
        x = s - 16384
        ema = ema + ((x - ema) >> 1)
        y = ((31000 * y1 - 15500 * y2) >> 14) + (ema >> 2)
        y = 32767 if y > 32767
        y = -32767 if y < -32767
        y2 = y1; y1 = y
        sum = ((sum * 31) ^ (y & 0x7FFF)) & 0x7FFF
        i += 1
      end
      (sum << 15) | s
    end

    SEED = 12345
    NS = [1, 8, 64, 512, 4096]
    TOTAL = 1 << 20   # iterations per row, held constant across the sweep

    puts "== parity (interp == AOT) =="
    ok = true
    NS.each do |n|
      a = bench_tick_rb(SEED, n)
      b = bench_tick(SEED, n)
      ok = false unless a == b
      puts "n=#{n}\\trb=#{a}\\taot=#{b}\\t#{a == b ? 'OK' : 'MISMATCH'}"
    end
    puts ok ? "parity: ALL OK" : "parity: FAILED"
    puts

    puts "== timing: total=#{TOTAL} iters/row =="
    puts "n\\tinterp(s)\\taot(s)\\tspeedup"
    NS.each do |n|
      k = TOTAL / n
      t0 = Time.now.to_f
      k.times { bench_tick_rb(SEED, n) }
      ti = Time.now.to_f - t0
      t1 = Time.now.to_f
      k.times { bench_tick(SEED, n) }
      ta = Time.now.to_f - t1
      sp = ta > 0 ? (ti / ta) : 0
      puts "#{n}\\t#{(ti).round(4)}\\t#{(ta).round(4)}\\t#{sp.round(1)}x"
    end
    """
    @State private var output: String = ""
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PicoRuby Runner").font(.headline)
            TextEditor(text: $source)
                .font(.system(.body, design: .monospaced))
                .frame(height: 120)
                .border(.gray)
                .focused($editorFocused)
            Button("Run") { run() }
                .buttonStyle(.borderedProminent)
            Text("Output").font(.subheadline)
            ScrollView {
                Text(output.isEmpty ? "—" : output)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: .infinity)
            .border(.gray)
        }
        .padding()
        // Tap outside the editor to dismiss the keyboard so the output is visible.
        .contentShape(Rectangle())
        .onTapGesture { editorFocused = false }
        // A Done button above the keyboard for explicit dismissal.
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { editorFocused = false }
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
