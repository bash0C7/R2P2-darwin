---
name: aot-pin-refresh
description: Use when checking whether this repo's AOT kernels (examples/ios/*/aot-kernel/) still build against the pinned spinel/suppify commits, or when advancing that pin to a newer suppify (and/or spinel) commit. For adding a NEW AOT kernel to an example, use aot-embed instead — this skill is about keeping existing kernels working over time.
---

# aot-pin-refresh: keep this repo's AOT kernels compiling against the pinned spinel/suppify

Every AOT kernel under `examples/ios/*/aot-kernel/*.rb` is regenerated from source by
spinel→suppify — neither tool is vendored; both are cloned ephemerally, the same way `cc`
is discovered on `PATH`. The exact commit pair this repo is verified against lives in one
file, `.github/aot-pins.yml`, read by both CI and the `aot:*` Rake tasks — never hardcode
either ref anywhere else.

## The Rake tasks (deterministic — always start here)

```sh
rake aot:pins                          # print the pinned spinel/suppify commits
rake aot:setup                         # clone+build both under build/aot (skips work
                                        # already at the pinned commit)
rake aot:regen                         # regenerate every kernel's picoruby-<kernel>/ gem
rake aot:refresh                       # regen, then Simulator-build every example that
                                        # has a kernel — the full "does the pin still
                                        # work" check; this is what CI runs
rake aot:bump_pins[<spinel>,<suppify>] # try a candidate pair; adopts into
                                        # .github/aot-pins.yml ONLY if aot:refresh passes
```

`bump_pins` never adopts a pair blindly — it runs the full `aot:refresh` first and only
overwrites `.github/aot-pins.yml` on success, mirroring suppify's own `check_pin`/
`bump_pin` split. A failed `bump_pins` leaves the pin file untouched; the failure and
`build/aot/{spinel,suppify}` (left at the candidate refs) are there to diagnose.

## Procedure

Create a TodoWrite item per step.

1. **Check suppify first, in its own repo** (`~/dev/src/github.com/bash0C7/suppify`, its
   own `spinel-tracking` skill). This repo's suppify pin should only ever advance to a
   suppify commit that repo's own `spinel:check_pin` has already verified — do not skip
   straight from an old suppify to a new spinel from here.
2. **Try the candidate pair**: `rake aot:bump_pins[<spinel-ref>,<suppify-ref>]`. This is
   the whole verification: clone+build spinel, checkout suppify, regenerate every AOT
   kernel gem, and Simulator-build every example that embeds one.
3. **If it passes**: `.github/aot-pins.yml` is now updated on disk. Before committing,
   actually run the app once (`rake ios:<example>:run` or `:observe`) and read its
   output — a Simulator *build* succeeding only proves the gem linked, not that its
   A/B/parity output is still correct (a spinel behavior change could compile fine and
   still produce wrong numbers). Confirm parity ("interpreted == AOT == GPU" or whatever
   the example's own seed asserts) before committing the pin bump.
4. **If it fails**: the failure is almost always the same handful of shapes spinel
   changes between commits — a runtime header rename, a generated-function C type
   rename, or a new/removed runtime source file. These are suppify's problem, not this
   repo's: go fix them in `~/dev/src/github.com/bash0C7/suppify` (its `spinel-tracking`
   skill), verify green there, push, and only then retry `aot:bump_pins` here with the
   fixed suppify commit. This repo's own code (`build_config/`, `project.yml`,
   `Sources/*.swift`) almost never needs to change for a spinel/suppify bump — if
   `aot:bump_pins` fails inside the Simulator build step itself (not the regen step),
   that is the one case where this repo's own wiring, not suppify, is the suspect.
5. **Stale build dir trap**: this repo's own compile rule keys strictly on a `.c` file's
   mtime, not its content. Regenerating a kernel gem in place can leave a same-named
   `.c` with a fresher mtime than a build directory's cached `.o` still wins the link if
   something upstream didn't touch in the expected order — if a Simulator build fails
   with undefined symbols right after a regen, `rm -rf build/ios-<example>-sim` and
   rebuild before assuming the pin itself is broken.
6. **Commit**: `.github/aot-pins.yml` alone (the regenerated `picoruby-<kernel>/` gems
   are gitignored build products — never commit them).

## Adding this to a new example

`aot_kernels` (in `rakelib/aot.rake`) discovers every `examples/ios/*/aot-kernel/*.rb`
automatically — a new example that follows the same layout (see the `aot-embed` skill)
is picked up by `aot:refresh`/`aot:bump_pins` with no Rakefile changes.
