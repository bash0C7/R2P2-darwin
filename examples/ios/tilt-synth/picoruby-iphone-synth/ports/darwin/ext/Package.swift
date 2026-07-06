// swift-tools-version:6.3
import PackageDescription

// picoruby-iphone-synth Darwin backend. A dynamic library whose @c exports
// (psynth_*) the port C calls. Linked into the APP target by project.yml.
// iOS 16 minimum for OSAllocatedUnfairLock (guards the render-thread targets
// against the concurrent VM-tick writer).
let package = Package(
  name: "PicoSynthDarwin",
  platforms: [.iOS(.v16), .macOS(.v13)],
  products: [
    .library(name: "PicoSynthDarwin", type: .dynamic, targets: ["PicoSynthDarwin"]),
  ],
  targets: [
    .target(name: "PicoSynthDarwin", path: "Sources/PicoSynthDarwin"),
  ]
)
