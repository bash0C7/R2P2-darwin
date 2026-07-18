#ifndef BENCH_TICK_H
#define BENCH_TICK_H

#include <stdint.h>
#include <stddef.h>

void bench_tick_init(void);
int bench_tick_error(void);
const char *bench_tick_error_message(void);
size_t bench_tick_str_len(const char *s);

intptr_t bench_tick(intptr_t lv_seed, intptr_t lv_n);

#endif
