# Deterministic `EXC_BAD_ACCESS` in `est_free`/`remove_free_block` during `mrb_close` teardown (custom-alloc VM, iOS Simulator arm64)

> **Draft — not yet posted.** Destination is either `picoruby/picoruby` or `picoruby/estalloc`
> (see "Victim vs culprit — open question" below; posting requires the maintainer's context).
> Report authored from R2P2-darwin (an Apple-platform build harness for PicoRuby); it does not
> modify picoruby/estalloc.

## Summary

When a PicoRuby VM created with `mrb_open_with_custom_alloc()` (estalloc allocator, `PICORB_ALLOC_ESTALLOC`)
is torn down with `mrb_close()`, the teardown **deterministically** crashes inside the estalloc free path:

```
Thread crashed: EXC_BAD_ACCESS (SIGSEGV) / KERN_INVALID_ADDRESS at 0x0000000000000022
  remove_free_block  (estalloc)
  est_free           (estalloc)   + 128
  <mrb_close teardown, mrb_basic_alloc_func>   (inlined)
  repl_eval          (host bridge)  -> the mrb_close(mrb) call site
```

Reproduced 5/5 times with an identical signature and identical fault address (`0x22`) on a frozen
environment. Skipping `mrb_close()` and instead reclaiming the whole estalloc pool by freeing the
backing heap avoids the crash (see Workaround).

## Environment

- picoruby: `bash0C7/picoruby` @ `port-darwin` (ref `8bafbb2a`), a superset of upstream master with
  Darwin ports. The crashing teardown code is in the vendored estalloc submodule and mruby GC, both
  unmodified from upstream.
- estalloc: `picoruby/estalloc` @ `971b793` (upstream master; the 4 commits after `971b793` do not
  touch `est_free`/`remove_free_block`/`add_free_block`).
- Target: iOS Simulator, arm64 (also relevant to any custom-alloc host build).
- Allocator / ABI defines: `PICORB_ALLOC_ESTALLOC`, `PICORB_ALLOC_ALIGN=8` (so
  `ESTALLOC_ALIGNMENT=8`, `ESTALLOC_ADDRESS_24BIT` default), `MRB_NO_BOXING`, `MRB_INT64`,
  `MRB_UTF8_STRING`, `MRB_USE_TASK_SCHEDULER=1`, `MRB_USE_VM_SWITCH_DISPATCH=1`.
- VM is opened on a caller-owned, zero-initialized 8 MB heap:
  `mrb_open_with_custom_alloc(heap, HEAP_SIZE)`.

## Minimal reproduction

Host bridge (C), reduced to the essential path:

```c
uint8_t *heap = calloc(1, HEAP_SIZE);                 /* 8 MB */
mrb_state *mrb = mrb_open_with_custom_alloc(heap, HEAP_SIZE);
/* compile + run a trivial program via mruby-compiler-prism + task scheduler */
mrc_ccontext *cc = mrc_ccontext_new(mrb);
mrc_irep *irep = mrc_load_string_cxt(cc, &src, len);  /* src = puts "hello 3" */
/* run irep as a task via mrb_task_run(mrb) */
mrc_ccontext_free(cc);
mrb_close(mrb);                                        /* <-- crashes in est_free */
free(heap);
```

Steps: build libmruby for the target, build the app/bridge with the defines above, launch. The
program compiles, runs, prints `hello 3`, then `mrb_close()` crashes during teardown — every run.

## What we ruled out (controlled experiment)

The libmruby archive and the app/bridge translation unit were initially built with two diverging
compile-time options:

| define | libmruby.a | app/bridge |
|---|---|---|
| `MRB_CONSTRAINED_BASELINE_PROFILE` | not set (posix build ⇒ `MRB_BASELINE_PROFILE=1`) | `=1` |
| `MRB_HEAP_PAGE_SIZE` | not set (gc.c default 1024) | `128` |

`MRB_CONSTRAINED_BASELINE_PROFILE` changes `sizeof(mrb_state)`, so a mismatch was the leading
hypothesis (an ABI skew between the archive and the bridge). **This was tested and rejected.**
Aligning libmruby's build to the app's defines — `MRB_HEAP_PAGE_SIZE=128` alone,
`MRB_CONSTRAINED_BASELINE_PROFILE=1` alone, and both together — each with a clean rebuild
(`rm -rf` the build dir; picoruby's per-object rule keys on `.c` mtime, not on the config, so stale
objects must be purged or the experiment is a silent no-op) — **still crashes deterministically**.
The crash is therefore in the teardown logic itself, not a build-option/ABI mismatch.

## Crash mechanism — leads from earlier investigation

> These structural details were gathered in a prior investigation (disassembly + memory inspection)
> and are provided as leads. They were not all re-verified in the deterministic-repro session above;
> treat them as hypotheses to confirm, not settled facts.

- Struct layout (`ESTALLOC_ADDRESS_24BIT`, `ESTALLOC_ALIGNMENT=8`): `FREE_BLOCK` =
  `size`(off 0) + `next_free`(0x08) + `prev_free`(0x10) + `top_adrs`(0x18), `sizeof` 32;
  `USED_BLOCK` `sizeof` 8; `BLOCK_ADRS(ptr) = ptr - 8`. `IS_PREV_FREE` is bit 1 of `size`.
- The fault is `remove_free_block` doing `ldr x8, [x1, #0x10]` (i.e. reading `prev_free` of a
  `FREE_BLOCK*`) where the pointer is invalid.
- `est_free`'s previous-block coalescing path (`estalloc.c:798-805` in the pinned tree) treats the
  preceding block as free based on `IS_PREV_FREE(target)` and dereferences the footer slot at
  `*(target-8)` as a `FREE_BLOCK*` **without validating it**. If that footer holds a stale/invalid
  value, the subsequent `remove_free_block` faults — matching the observed signature.
- A standalone estalloc fuzz (public API only, >1M mixed alloc/free ops) never broke the
  footer/`PREV_FREE` invariant on its own. Footer inconsistency only appeared when injected
  manually. This is a negative result: estalloc's own API does not self-corrupt the footer under
  random workloads.

## Victim vs culprit — open question

Given the above, two explanations remain and are **not yet decided**:

1. **estalloc mis-reads a valid-but-stale footer** (estalloc as victim of an unchecked assumption):
   the `IS_PREV_FREE`-then-dereference path trusts a footer that a prior in-bounds write left stale.
2. **Something on the mruby side writes out of bounds** and corrupts estalloc's block metadata
   (estalloc as victim of an external OOB write), which estalloc then reads.

Deciding between them requires catching the write that places `0x22` (or any invalid value) into the
faulting free-block field. Concretely: on the deterministic repro, set a hardware watchpoint on the
crash target's `size`/footer address and on the `prev_free` slot, and identify the writing frame —
whether it is an estalloc function operating on stale metadata, or an mruby write outside the
allocation it was handed.

## Workaround (in the harness, no upstream change)

Skip `mrb_close()` on the success path and let `free(heap)` reclaim the entire estalloc pool at
once. Because every VM allocation lives inside the caller-owned heap passed to
`mrb_open_with_custom_alloc()`, freeing the heap releases all VM memory without walking estalloc's
free-block teardown. This mirrors picoruby's own `cleanup()`. It avoids the crash but does not run
`mrb_close`'s other teardown; it is acceptable here because the VM's memory is entirely within the
estalloc pool.

## What would definitively resolve this

The deterministic reproduction now exists, so the remaining step is the watchpoint observation
described under "Victim vs culprit" to attribute the corrupting/mis-read write, then fix on the
correct side (add footer validation in estalloc's coalescing path, or fix the mruby-side write).
