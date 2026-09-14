#include "mruby.h"
#include "mruby/presym.h"
#include "../../include/gpu_bench.h"

static mrb_value
mrb_gpu_bench_tick(mrb_state *mrb, mrb_value self)
{
  mrb_int seed, n, k;
  mrb_get_args(mrb, "iii", &seed, &n, &k);

  int64_t out = 0;
  if (!GPU_BENCH_tick((int64_t)seed, (int32_t)n, (int32_t)k, &out)) {
    mrb_raise(mrb, E_RUNTIME_ERROR, "GPU bench_tick unavailable or lane mismatch");
  }
  return mrb_int_value(mrb, (mrb_int)out);
}

static mrb_value
mrb_gpu_bench_available_p(mrb_state *mrb, mrb_value self)
{
  return mrb_bool_value(GPU_BENCH_available());
}

void
mrb_picoruby_gpu_bench_gem_init(mrb_state *mrb)
{
  struct RClass *krn = mrb->kernel_module;
  mrb_define_module_function_id(mrb, krn, MRB_SYM(gpu_bench_tick), mrb_gpu_bench_tick, MRB_ARGS_REQ(3));
  mrb_define_module_function_id(mrb, krn, MRB_SYM_Q(gpu_bench_available), mrb_gpu_bench_available_p, MRB_ARGS_NONE());
}

void
mrb_picoruby_gpu_bench_gem_final(mrb_state *mrb)
{
}
