---
name: aot-embed
description: "Use when adding spinel/suppify AOT native acceleration to a hot Ruby/PicoRuby method in an R2P2-darwin Apple example (iOS/macOS/watchOS, e.g. the repl PicoRubyRunner), and want the interpreted version kept in-tree for A/B benchmarking on the Simulator or a real device."
---

# aot-embed: run a Ruby kernel as native AOT inside an R2P2-darwin app

Compile one hot Ruby method to native with spinel→suppify, embed it as an mrbgem in an
R2P2-darwin Apple example, and keep the interpreted original in-tree as the A/B baseline.
The kernel has one source of truth (a plain-Ruby file); the app calls the same method
name whether it runs interpreted or native.

## When this pays off

AOT wins only for the right shape — confirm the target method is:

- **compute-bound**, not I/O-bound. If the loop waits on sensors/serial/GC, native math changes nothing.
- **amortizable per call**. Each native call pays a fixed boundary cost (VM dispatch + arg
  check + spinel's `setjmp`). A method that loops many times *inside one call* amortizes it;
  a scalar called once per iteration hides the speedup under it. Measured on iPhone 16e:
  ~1.1× at 1 iter/call → 50× at 4096 iters/call.
- **flat scalars in / scalar out, no allocation**. Types across the boundary: `Integer`,
  `Float`, `String`, `Symbol`, bool, nil, void. No `Array`/`Hash`/objects.

Apple platforms are 64-bit with `MRB_INT64`, so — unlike a 32-bit MCU — you do **not** pack
wide results across the boundary; `intptr_t` is 64-bit here.

If the method fails these, say so and stop — AOT won't help it.

## Prerequisites

spinel and suppify are external tools, discovered like `cc` — never vendored into this repo.

- spinel binary + runtime (`sp_runtime.h`, `libspinel_rt.a`): via `SPINEL` / `SPINEL_LIB`.
- a suppify checkout: run its `suppify.rb`.

## Steps

Create a TodoWrite item per step. `<example>` is an iOS example dir (proven on `repl`);
`<name>` names the gem and its C API. The Ruby method keeps its own `def` name.

### 1. Extract the kernel to a standalone source

`examples/ios/<example>/aot-kernel/<name>.{rb,rbs}` — the method as a public top-level
`def`, plus an `.rbs` sidecar (spinel drops uncalled top-level methods without a signature).
This body is also the interpreted baseline; do not fork it.

```ruby
# <name>.rb — single source of truth
def <name>(seed, n)
  # integer/float work, bounded loop, no allocation
end
```

```rbs
class Object
  def <name>: (Integer, Integer) -> Integer
end
```

### 2. Generate the mrbgem (a reproducible build product, not committed)

Run from the kernel dir; spinel/suppify are external tools discovered like `cc`:

```sh
cd examples/ios/<example>/aot-kernel
SPINEL=/path/to/spinel/spinel SPINEL_LIB=/path/to/spinel/lib \
  ruby /path/to/suppify/suppify.rb <name>.rb -o <name> -t picoruby -d ..
#   -> examples/ios/<example>/picoruby-<name>/   (an mrbgem)
```

Gitignore the generated `picoruby-<name>/`: it is deterministic for a given
spinel/suppify version, so regenerate it rather than committing it — mirroring how
`vendor/picoruby` is fetched, not vendored. Never hand-edit the generated C /
mrbgem.rake — to change the kernel, edit `<name>.rb` and re-run suppify. The
generated `binding.c` is dual-VM (`#if defined(PICORB_VM_MRUBYC)`);
R2P2-darwin builds the **full-mruby** branch, whose `mrb_picoruby_<name>_gem_init` registers
the method on `kernel_module` at `mrb_open`. So **no `require` is needed** in the app
(unlike mruby/c firmware, where the gem is activated by `require`).

### 3. Wire the gem into the build_config

Add one line to **both** `build_config/r2p2-picoruby-ios-<example>-{sim,device}.rb`, right
after `conf.gem core: "mruby-compiler"`:

```ruby
conf.gem File.expand_path("../examples/ios/<example>/picoruby-<name>", __dir__)
```

### 4. Seed the A/B comparison

In the example's seed, define the interpreted baseline under a distinct name (`<name>_rb`)
with the same body, assert parity against the native `<name>`, then time both. Drive with a
batch size `n` and hold the total work fixed, so the interpreter stays a flat reference line
and the AOT speedup shows the boundary cost amortizing as `n` grows:

```ruby
raise "mismatch" unless <name>_rb(SEED, n) == <name>(SEED, n)
# for each n in a small→large sweep, time k.times { ... } with k*n held constant
```

### 5. Build so the gem reaches the app

```sh
rm -rf build/ios-<example>-sim          # picoruby's per-object rule keys on the .c mtime,
rake ios:<example>:lib ios:<example>:gen ios:<example>:build   # so a stale .o silently wins
```

`:lib` cross-builds `libmruby.a` through the build_config and stages it under
`examples/ios/<example>/Vendor/lib`. Verify the gem is actually in the archive before
trusting behavior:

```sh
nm examples/ios/<example>/Vendor/lib/libmruby.a | grep -c "_<name>"   # expect >= 1
```

### 6. Measure — Simulator, then device

- **Simulator**: `rake ios:<example>:observe` launches the app N times and captures each
  run's output under `build/observe/<example>_run*.txt` — read the A/B table there. The
  observe OK/CRASH classifier keys on the stock example's golden string, so a custom bench
  seed reads as `unknown`; that is not a crash (confirm no new `.ips` landed).
- **Device**: set `DEVELOPMENT_TEAM` in `examples/ios/<example>/project.yml`, then
  `rake ios:<example>:device:all`. The `--console` launch streams the app's stdout — the
  real-hardware A/B table appears there.

### 7. Keep the baseline

The interpreted `<name>.rb` and the `<name>_rb` seed stay in-tree permanently. That
coexistence is the deliverable, not scaffolding to delete.

## Known constraint (repl example)

The repl example's VM teardown hits an estalloc `est_free` crash on iOS. `bridge/picoruby_bridge.c`
works around it by skipping `mrb_close` on the success paths and reclaiming the whole heap
with `free()`. If you add a new bridge path that closes a VM, mirror that. Root cause is
tracked as R2P2-darwin issue #9.
