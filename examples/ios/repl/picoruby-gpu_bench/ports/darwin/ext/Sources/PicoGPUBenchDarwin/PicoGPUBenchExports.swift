import Metal

// C-callable surface for ports/darwin/gpu_bench.c. Uses `@c` (SE-0495) like
// PicoTorchExports and PicoBLEExports. Direction is C -> Swift only.
//
// The kernel is the same recurrence as examples/ios/repl/aot-kernel/
// bench_tick.rb (LCG -> EMA -> Q14 resonator -> rolling checksum),
// transliterated to Metal Shading Language. It is compiled from source at
// runtime (MTLDevice.makeLibrary(source:)), so no Xcode Metal-compiler
// build phase or bundled .metallib is needed — the app stays "behaviour in
// a text file, compiled on launch" all the way down, matching how app.rb
// itself is compiled by the prism compiler inside the VM.

private let kernelSource = """
#include <metal_stdlib>
using namespace metal;

kernel void bench_tick_kernel(constant long& seed [[buffer(0)]],
                               constant int& n [[buffer(1)]],
                               device long* out [[buffer(2)]],
                               uint tid [[thread_position_in_grid]])
{
  long s = seed & 0x7FFF;
  long y1 = 0, y2 = 0, ema = 0, sum = 0;
  for (int i = 0; i < n; i++) {
    s = (s * 75 + 74) & 0x7FFF;
    long x = s - 16384;
    ema = ema + ((x - ema) >> 1);
    long y = ((31000 * y1 - 15500 * y2) >> 14) + (ema >> 2);
    if (y > 32767) { y = 32767; }
    if (y < -32767) { y = -32767; }
    y2 = y1;
    y1 = y;
    sum = ((sum * 31) ^ (y & 0x7FFF)) & 0x7FFF;
  }
  out[tid] = (sum << 15) | s;
}
"""

private final class GPUBenchContext {
  let device: MTLDevice
  let queue: MTLCommandQueue
  let pipeline: MTLComputePipelineState

  init?() {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else { return nil }
    do {
      let library = try device.makeLibrary(source: kernelSource, options: nil)
      guard let function = library.makeFunction(name: "bench_tick_kernel") else { return nil }
      self.device = device
      self.queue = queue
      self.pipeline = try device.makeComputePipelineState(function: function)
    } catch {
      return nil
    }
  }
}

// Built once, lazily, on first use — mirrors the persistent-VM-shim idea:
// the GPU context is a resident resource the app opens once, not per call.
// MTLDevice/MTLCommandQueue/MTLComputePipelineState are Apple-documented
// thread-safe for concurrent command-buffer creation, so the immutable
// reference held here needs no actor isolation.
private nonisolated(unsafe) let context = GPUBenchContext()

// Every one of the `k` threads runs the identical (seed, n) recurrence,
// so all k lanes must produce the same value; that agreement doubles as
// the GPU-side parity check (interpreted/AOT already check each other in
// ContentView.swift). Returns 1 and writes the shared result to `out` on
// success; returns 0 if Metal is unavailable or any lane disagrees.
@c public func pgpu_bench_tick_run(_ seed: Int64, _ n: Int32, _ k: Int32, _ out: UnsafeMutablePointer<Int64>) -> Int32 {
  guard let ctx = context, k > 0 else { return 0 }

  guard let outBuffer = ctx.device.makeBuffer(length: Int(k) * MemoryLayout<Int64>.size, options: .storageModeShared),
        let commandBuffer = ctx.queue.makeCommandBuffer(),
        let encoder = commandBuffer.makeComputeCommandEncoder() else { return 0 }

  var seedVar = seed
  var nVar = n
  encoder.setComputePipelineState(ctx.pipeline)
  encoder.setBytes(&seedVar, length: MemoryLayout<Int64>.size, index: 0)
  encoder.setBytes(&nVar, length: MemoryLayout<Int32>.size, index: 1)
  encoder.setBuffer(outBuffer, offset: 0, index: 2)

  let gridSize = MTLSize(width: Int(k), height: 1, depth: 1)
  let threadgroupWidth = min(Int(k), ctx.pipeline.maxTotalThreadsPerThreadgroup)
  let threadgroupSize = MTLSize(width: threadgroupWidth, height: 1, depth: 1)
  encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
  encoder.endEncoding()
  commandBuffer.commit()
  commandBuffer.waitUntilCompleted()

  if commandBuffer.status == .error {
    return 0
  }

  let results = outBuffer.contents().bindMemory(to: Int64.self, capacity: Int(k))
  let first = results[0]
  for i in 1..<Int(k) {
    if results[i] != first { return 0 }
  }
  out.pointee = first
  return 1
}

@c public func pgpu_bench_tick_available() -> Int32 {
  context != nil ? 1 : 0
}
