import CoreMotion
import os

// C-callable surface for ports/darwin/motion.c. Uses `@c` (SE-0495) like
// PicoTorchExports. Direction is C -> Swift only.
//
// CMMotionManager's callback runs on the main queue while pmotion_pitch/
// pmotion_roll are called from the VM tick thread, so the latest sample is
// guarded by a lock (unlike torch, which is fire-and-forget with no
// concurrent readers/writers). Only the two Double fields we actually need
// are extracted into AttitudeSample and stored behind the lock, so the lock
// never has to hold CMDeviceMotion itself (which predates Swift concurrency
// and isn't Sendable) — no @preconcurrency needed here.

private struct AttitudeSample: Sendable {
  let pitch: Double
  let roll: Double
}

// manager is only touched via ensureUpdatesStarted() and the plain accessor
// calls below, both callable from the VM tick thread or CoreMotion's own
// callback; CMMotionManager tolerates being driven this way.
private nonisolated(unsafe) let manager = CMMotionManager()
private let latest = OSAllocatedUnfairLock<AttitudeSample?>(initialState: nil)

private func ensureUpdatesStarted() {
  guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
  manager.deviceMotionUpdateInterval = 1.0 / 60.0
  manager.startDeviceMotionUpdates(to: .main) { motion, _ in
    guard let motion else { return }
    let sample = AttitudeSample(pitch: motion.attitude.pitch, roll: motion.attitude.roll)
    latest.withLock { $0 = sample }
  }
}

@c public func pmotion_available() -> Int32 {
  ensureUpdatesStarted()
  return manager.isDeviceMotionAvailable ? 1 : 0
}

@c public func pmotion_pitch() -> Double {
  ensureUpdatesStarted()
  return (latest.withLock { $0 }?.pitch ?? 0) * 180.0 / .pi
}

@c public func pmotion_roll() -> Double {
  ensureUpdatesStarted()
  return (latest.withLock { $0 }?.roll ?? 0) * 180.0 / .pi
}
