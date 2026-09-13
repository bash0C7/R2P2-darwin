#include "../../include/gpu_bench.h"

/* Provided by the PicoGPUBenchDarwin Swift package (@c exports), resolved at
 * app link time. Declared here so the cross-build needs no generated
 * -Swift.h (same convention as ports/darwin/torch.c). */
extern int pgpu_bench_tick_run(int64_t seed, int32_t n, int32_t k, int64_t *out);
extern int pgpu_bench_tick_available(void);

bool
GPU_BENCH_tick(int64_t seed, int32_t n, int32_t k, int64_t *out)
{
  return pgpu_bench_tick_run(seed, n, k, out) != 0;
}

bool
GPU_BENCH_available(void)
{
  return pgpu_bench_tick_available() != 0;
}
