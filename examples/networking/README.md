# Networking — HTTP/TLS from Ruby (picoruby-net over mbedTLS)

The whole HTTP/TLS round-trip is **Ruby**. `app.rb` calls `Net::HTTPSClient`, which
comes from the upstream `picoruby-net` gem: on iOS it dials a raw BSD socket and
runs the TLS handshake through mbedTLS (`picoruby-net`'s `ports/posix/tls_client.c`),
seeded by the `picoruby-mbedtls`/`picoruby-rng` **Darwin** entropy ports
(`SecRandomCopyBytes` via `-framework Security`). There is **no OpenSSL** and
**no Apple URL-loading API** (`URLSession`/`CFNetwork`) involved, so App
Transport Security — which only governs those APIs — is bypassed entirely: this
app's TLS is PicoRuby's own, running on-device.

This is the one example that needs the **full-REPL gembox** (`posix?=true` +
the `conf.ports :darwin, :posix` port-chain — see the root README's
"Constraints worth knowing"), not the reduced VM the other examples use:
`picoruby-net`/`picoruby-mbedtls`/`picoruby-rng` all assume a POSIX-shaped
`build.posix?` branch.

## How it works

```
[SwiftUI FETCH button]
  --VMExecutor.shared.call("fetch")-->  $app (Ruby, NetApp)  -->  Net::HTTPSClient.new(HOST).get(PATH)
    --> picoruby-net (mruby glue)                  src/mruby/net.c
    --> ports/posix/tls_client.c                   raw BSD socket + mbedTLS handshake
    --> mbedTLS entropy source                     picoruby-mbedtls Darwin port -> SecRandomCopyBytes
```

`VMExecutor.swift` boots the VM once on appear (persistent VM, like
`virtual-peripheral`/`iphone-torch`) and additionally auto-invokes
`call("fetch")` right after `vm_open` returns, so a TLS round-trip result is
readable from `devicectl ... process launch --console` (NSLog-mirrored)
without a manual tap — the `FETCH` button still works for interactive re-runs.

## The behaviour is Ruby — and you can prove it

`app.rb` ships as a plain-text resource and is compiled **at runtime, inside
the app**, by PicoRuby's prism compiler when the VM boots. Change `HOST`/`PATH`
in `app.rb`, reinstall, and the request changes with **no rebuild** of
`libmruby.a` or the Swift layer — a successful response means the mbedTLS
handshake completed on iOS using the Darwin entropy port, driven entirely by
that Ruby file.

**Known limitation** (see `app.rb`'s header comment): `picoruby-net`'s POSIX
TLS port sets `MBEDTLS_SSL_VERIFY_NONE` — it completes the handshake but does
**not** validate the server certificate. This example demonstrates
connectivity + handshake, not a trust decision.

## Depends on a fork fix

This example only works against a `vendor/picoruby` that carries the
`picoruby-net` POSIX recv-buffer allocator fix — see the root README's
["Fork fix: picoruby-net POSIX recv-buffer allocator"](../../README.md#fork-fix-picoruby-net-posix-recv-buffer-allocator)
section. Without it, a response arriving over the custom `estalloc` VM
allocator corrupts the free-list and crashes right after the handshake
completes (looks like a hang, since captured stdout only flushes on return).

## Build & run

Prerequisites: full `Xcode.app`, iOS SDK, `xcodegen` (`rake check`).

### Simulator

```sh
rake ios:net:all      # cross-build libmruby.a -> xcodegen -> build -> launch
```

### Device (real TLS handshake)

```sh
rake ios:net:device:all   # needs a connected, signed iOS device
```

On a real device, tapping FETCH (or the boot-time auto-fetch) logs
`handshake OK, response received (N bytes)` and `status: HTTP/1.1 200 OK`.

## Individual rake tasks

| Task | What it does |
|------|--------------|
| `rake ios:net:lib` | cross-build `libmruby.a` (Simulator) with picoruby-net + mbedTLS/rng darwin ports, stage under `Vendor/` |
| `rake ios:net:gen` | generate `Networking.xcodeproj` from `project.yml` |
| `rake ios:net:build` | build the app for the Simulator |
| `rake ios:net:run` | boot a Simulator, install, launch |
| `rake ios:net:device:lib` | cross-build `libmruby.a` for the device SDK |
| `rake ios:net:device:build` | build signed for a connected device |
| `rake ios:net:device:run` | install + launch on the connected device |
| `rake ios:net:device:all` | full device pipeline: lib → gen → build → run |
