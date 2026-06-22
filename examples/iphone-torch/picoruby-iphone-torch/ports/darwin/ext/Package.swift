// swift-tools-version:6.3
import PackageDescription

// picoruby-iphone-torch Darwin backend. A dynamic library whose @c exports
// (ptorch_*) the port C calls. Linked into the APP target by project.yml.
let package = Package(
  name: "PicoTorchDarwin",
  platforms: [.iOS(.v13), .macOS(.v11)],
  products: [
    .library(name: "PicoTorchDarwin", type: .dynamic, targets: ["PicoTorchDarwin"]),
  ],
  targets: [
    .target(name: "PicoTorchDarwin", path: "Sources/PicoTorchDarwin"),
  ]
)
