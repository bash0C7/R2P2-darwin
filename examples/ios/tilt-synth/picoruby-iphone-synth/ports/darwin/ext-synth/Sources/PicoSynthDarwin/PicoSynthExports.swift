import AVFoundation
import os

// C-callable surface for ports/darwin/synth.c. Uses `@c` (SE-0495) like
// PicoTorchExports/PicoMotionExports. Direction is C -> Swift only.
//
// The render block runs on the real-time audio thread; psynth_set_note/
// psynth_set_fm_depth are called from the VM tick thread. Target values are
// guarded by a lock, and the render block ramps its own internal "current"
// value toward the target over ~15ms to avoid audible clicks from
// app.rb's discrete note-quantization jumps. This ramp is purely an
// anti-click measure -- the note mapping itself stays a hard snap, decided
// entirely in Ruby.

// nonisolated(unsafe): engine/sourceNode are touched from two different
// queues -- the VM-tick queue (psynth_start/psynth_stop) and the main queue
// (the interruption handler installed below, which calls .pause()/.start()
// on .began/.ended). This is NOT single-writer; safety instead relies on
// AVAudioEngine's own transport calls (start/stop/pause) tolerating
// cross-queue use, which is the standard pattern Apple's interruption-
// handling docs recommend. interruptionObserver genuinely IS single-writer:
// it is only ever set once, inside installInterruptionHandlerOnce, guarded
// by the `== nil` check. renderState is touched only from inside the
// AVAudioSourceNode render closure itself (the real-time audio thread),
// never concurrently from elsewhere. None of this is visible to the Swift 6
// strict-concurrency checker since these are globals, so the annotation
// documents/asserts the safety argument above.
private nonisolated(unsafe) let engine = AVAudioEngine()
private nonisolated(unsafe) var sourceNode: AVAudioSourceNode?
private let targetFreq  = OSAllocatedUnfairLock<Double>(initialState: 440.0)
private let targetDepth = OSAllocatedUnfairLock<Double>(initialState: 0.0)

private final class RenderState {
  var currentFreq: Double = 440.0
  var currentDepth: Double = 0.0
  var carrierPhase: Double = 0.0
  var modPhase: Double = 0.0
}

private nonisolated(unsafe) let renderState = RenderState()

// Audio interruptions (phone call, Siri, etc.) are handled here only -- Ruby
// never sees them. On .began we let the engine stop itself; on .ended with
// .shouldResume we restart it so playback recovers without app.rb doing
// anything (per the design's error-handling section).
private nonisolated(unsafe) var interruptionObserver: NSObjectProtocol?

private func installInterruptionHandlerOnce() {
  guard interruptionObserver == nil else { return }
  interruptionObserver = NotificationCenter.default.addObserver(
    forName: AVAudioSession.interruptionNotification,
    object: AVAudioSession.sharedInstance(),
    queue: .main
  ) { note in
    guard let info = note.userInfo,
          let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
    switch type {
    case .began:
      engine.pause()
    case .ended:
      let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
      if AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume) {
        try? engine.start()
      }
    @unknown default:
      break
    }
  }
}

@c public func psynth_start() -> Int32 {
  installInterruptionHandlerOnce()
  guard sourceNode == nil else { return 1 }
  let format = engine.mainMixerNode.outputFormat(forBus: 0)
  let sampleRate = format.sampleRate

  let node = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
    let rampStep = 1.0 / (0.015 * sampleRate)   // ~15ms ramp to target, click-avoidance only
    let freq  = targetFreq.withLock  { $0 }
    let depth = targetDepth.withLock { $0 }
    let modFreq = 5.0     // fixed low modulator rate (Hz): a gentle FM timbre sweep
    let modRangeHz = 40.0 // max carrier deviation at full depth

    let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
    for frame in 0..<Int(frameCount) {
      renderState.currentFreq  += (freq  - renderState.currentFreq)  * rampStep
      renderState.currentDepth += (depth - renderState.currentDepth) * rampStep

      let modValue = sin(renderState.modPhase) * renderState.currentDepth * modRangeHz
      let instantFreq = renderState.currentFreq + modValue
      let sample = Float(sin(renderState.carrierPhase) * 0.2)  // fixed headroom, PoC scope

      for buffer in ablPointer {
        let buf = buffer.mData!.assumingMemoryBound(to: Float.self)
        buf[frame] = sample
      }

      renderState.carrierPhase += 2.0 * .pi * instantFreq / sampleRate
      if renderState.carrierPhase > 2.0 * .pi { renderState.carrierPhase -= 2.0 * .pi }
      renderState.modPhase += 2.0 * .pi * modFreq / sampleRate
      if renderState.modPhase > 2.0 * .pi { renderState.modPhase -= 2.0 * .pi }
    }
    return noErr
  }

  engine.attach(node)
  engine.connect(node, to: engine.mainMixerNode, format: format)
  sourceNode = node

  do {
    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    try AVAudioSession.sharedInstance().setActive(true)
    try engine.start()
    return 1
  } catch {
    return 0
  }
}

@c public func psynth_stop() -> Int32 {
  engine.stop()
  // Note: sourceNode is left non-nil, so a later psynth_start() hits the
  // `sourceNode == nil` guard and returns early without restarting the
  // engine. Unreachable today (app.rb never calls Synth#stop) but a future
  // stop->start cycle would need `sourceNode = nil` here to actually work.
  return 1
}

@c public func psynth_set_note(_ hz: Double) -> Int32 {
  guard hz > 0 else { return 0 }
  targetFreq.withLock { $0 = hz }
  return 1
}

@c public func psynth_set_fm_depth(_ depth: Double) -> Int32 {
  let clamped = min(max(depth, 0.0), 1.0)
  targetDepth.withLock { $0 = clamped }
  return 1
}
