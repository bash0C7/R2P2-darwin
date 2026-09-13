#ifndef PICORUBY_GPU_BENCH_H
#define PICORUBY_GPU_BENCH_H

#include <stdint.h>
#include <stdbool.h>

/* Runs `k` independent, parallel evaluations of the same bench_tick(seed, n)
 * recurrence (examples/ios/repl/aot-kernel/bench_tick.rb) on the GPU, one
 * per thread. Every thread runs the identical recurrence (same seed, same
 * n), so all k results must agree — that agreement is the GPU-side parity
 * check, mirroring the interpreted/AOT parity check in ContentView.swift.
 * Writes the checksum to `out` and returns true on success; returns false
 * if Metal is unavailable, or if any lane disagrees with lane 0. */
bool GPU_BENCH_tick(int64_t seed, int32_t n, int32_t k, int64_t *out);

/* True if this device can run the GPU kernel. */
bool GPU_BENCH_available(void);

#endif /* PICORUBY_GPU_BENCH_H */
