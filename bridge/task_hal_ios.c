/*
** task_hal_ios.c — Minimal iOS (Simulator) task HAL for mruby-task
**
** Uses a polling approach instead of SIGALRM + setitimer.
** The iOS Simulator's routing of SIGALRM causes intermittent heap corruption
** in estalloc when the signal fires during a critical section.  Since
** PicoRubyRunner only runs single, synchronous Ruby snippets (no concurrent
** tasks or Task.sleep calls), a signal-free, polling HAL is sufficient.
**
** mrb_hal_task_idle_cpu calls mrb_tick so the scheduler can advance even
** without a background timer.  mrb_hal_task_sleep_us busy-waits.
** mrb_task_disable_irq / mrb_task_enable_irq are no-ops because there is no
** asynchronous interrupt to protect against.
*/

#include <mruby.h>
#include "task_hal.h"
#include <time.h>
#include <unistd.h>
#include <stdint.h>

#define NSEC_PER_SEC  1000000000ULL
#define NSEC_PER_MSEC 1000000ULL

static mrb_state *hal_mrb = NULL;

void
mrb_hal_task_init(mrb_state *mrb)
{
  int i;
  for (i = 0; i < 4; i++) {
    mrb->task.queues[i] = NULL;
  }
  mrb->task.tick = 0;
  mrb->task.wakeup_tick = UINT32_MAX;
  mrb->task.switching = FALSE;
  hal_mrb = mrb;
}

void
mrb_hal_task_final(mrb_state *mrb)
{
  (void)mrb;
  hal_mrb = NULL;
}

/* No interrupt to enable/disable — no-op. */
void
mrb_task_enable_irq(void)
{
  /* no-op: no SIGALRM on iOS */
}

void
mrb_task_disable_irq(void)
{
  /* no-op: no SIGALRM on iOS */
}

/* Drive the tick manually so the scheduler can make progress. */
void
mrb_hal_task_idle_cpu(mrb_state *mrb)
{
  mrb_tick(mrb);
  /* Yield briefly so other threads can run if needed. */
  usleep(MRB_TICK_UNIT * 1000);
}

void
mrb_hal_task_sleep_us(mrb_state *mrb, mrb_int usec)
{
  struct timespec start, now;
  (void)mrb;
  if (usec <= 0) return;

  clock_gettime(CLOCK_MONOTONIC, &start);
  uint64_t target_ns = (uint64_t)usec * 1000ULL;

  while (1) {
    clock_gettime(CLOCK_MONOTONIC, &now);
    uint64_t elapsed_ns =
      (uint64_t)(now.tv_sec  - start.tv_sec)  * NSEC_PER_SEC +
      (uint64_t)(now.tv_nsec - start.tv_nsec);
    if (elapsed_ns >= target_ns) break;
    /* Tick the scheduler while waiting. */
    if (hal_mrb) mrb_tick(hal_mrb);
    usleep(MRB_TICK_UNIT * 1000);
  }
}
