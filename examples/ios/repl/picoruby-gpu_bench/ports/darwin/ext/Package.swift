// swift-tools-version:6.3
import PackageDescription

// picoruby-gpu_bench Darwin backend. A dynamic library whose @c exports
// (pgpu_bench_tick_*) the port C calls. Linked into the APP target by
// project.yml — same convention as PicoTorchDarwin.
let package = Package(
  name: "PicoGPUBenchDarwin",
  platforms: [.iOS(.v13), .macOS(.v11)],
  products: [
    .library(name: "PicoGPUBenchDarwin", type: .dynamic, targets: ["PicoGPUBenchDarwin"]),
  ],
  targets: [
    .target(name: "PicoGPUBenchDarwin", path: "Sources/PicoGPUBenchDarwin"),
  ]
)
