// swift-tools-version:6.3
import PackageDescription

// picoruby-iphone-motion Darwin backend. A dynamic library whose @c exports
// (pmotion_*) the port C calls. Linked into the APP target by project.yml.
// iOS 16 minimum (not v13 like PicoTorchDarwin): OSAllocatedUnfairLock, used
// to guard the CoreMotion sample against the concurrent VM-tick reader,
// requires iOS 16+.
let package = Package(
  name: "PicoMotionDarwin",
  platforms: [.iOS(.v16), .macOS(.v13)],
  products: [
    .library(name: "PicoMotionDarwin", type: .dynamic, targets: ["PicoMotionDarwin"]),
  ],
  targets: [
    .target(name: "PicoMotionDarwin", path: "Sources/PicoMotionDarwin"),
  ]
)
