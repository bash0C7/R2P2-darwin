# Networking — HTTP/TLS from Ruby (Net::HTTP over picoruby-socket + mbedTLS)

日本語版: [README_jp.md](README_jp.md)

The whole HTTP/TLS round-trip is Ruby. `app.rb` calls `Net::HTTP` from the
upstream `picoruby-net-http` gem on top of `picoruby-socket`: on iOS the socket
gem's darwin port (fork `port-darwin`, `ports/darwin/ssl_socket.c`) dials a raw
BSD socket and runs the TLS handshake through mbedTLS, seeded by the
`picoruby-mbedtls`/`picoruby-rng` Darwin entropy ports (`SecRandomCopyBytes`
via `-framework Security`). No OpenSSL and no Apple URL-loading API
(`URLSession`/`CFNetwork`) is involved, so App Transport Security — which governs
only those APIs — does not apply: this app's TLS is PicoRuby's own, running
on-device.

This is the one example that needs the full-REPL gembox (`posix?=true` plus the
`conf.ports :darwin, :posix` port chain — see the gembox notes in
[How it fits together](../../../README.md#how-it-fits-together)), not the reduced VM
the other examples use: `picoruby-socket`/`picoruby-mbedtls`/`picoruby-rng` all
assume a POSIX-shaped `build.posix?` branch.

## How it works

The FETCH button drives one call chain from SwiftUI down to mbedTLS; every layer
below the bridge is Ruby or picoruby-socket C.

```
[SwiftUI FETCH button]
  --VMExecutor.shared.call("fetch")-->  $app (Ruby, NetApp)  -->  Net::HTTP.new(HOST, 443).get(PATH)
    --> picoruby-net-http (Ruby)                   SSLSocket.open(host, port, ctx)
    --> picoruby-socket (mruby glue)               src/mruby/ssl_socket.c
    --> ports/darwin/ssl_socket.c                  raw BSD socket + mbedTLS handshake
    --> mbedTLS entropy source                     picoruby-mbedtls Darwin port -> SecRandomCopyBytes
```

`VMExecutor.swift` boots the VM once on appear (persistent VM, like
`virtual-peripheral`/`iphone-torch`) and auto-invokes `call("fetch")` right after
`vm_open` returns, so a TLS round-trip result is readable from
`devicectl ... process launch --console` (NSLog-mirrored) without a manual tap.
The FETCH button re-runs it interactively.

`app.rb` ships as a plain-text resource and is compiled at runtime, inside the
app, by PicoRuby's prism compiler when the VM boots.

- Change `HOST`/`PATH` in `app.rb` and reinstall: the request changes with no
  rebuild of `libmruby.a` or the Swift layer.
- A successful response means the mbedTLS handshake completed on iOS using the
  Darwin entropy port, driven entirely by that Ruby file.
- Known limitation (see the comment in `app.rb`'s `fetch`): the demo sets
  `verify_mode = SSLContext::VERIFY_NONE` because iOS ships no PEM CA bundle
  for mbedTLS to verify against — it completes the handshake but does not
  validate the server certificate. To verify, bundle a CA PEM as a resource
  and hand it to `SSLContext#ca=`. This example demonstrates connectivity plus
  handshake, not a trust decision.

## Dependencies

This example only works against a `vendor/picoruby` that carries
`picoruby-socket`'s darwin port (BSD sockets + mbedTLS), which the default
fetch (`bash0C7/picoruby`, branch `port-darwin`) includes — see
[Vendor fork](../../../README.md#vendor-fork) in the root README. Upstream
`picoruby/picoruby` has only the posix port, whose TLS links OpenSSL, which
iOS does not ship.

## Build & run

Prerequisites: full `Xcode.app`, iOS SDK, `xcodegen` (`rake check` verifies
them).

### Simulator

```sh
rake ios:net:all      # cross-build libmruby.a -> xcodegen -> build -> launch
```

### Device

Real TLS handshake; needs a connected, signed iOS device. On the first
on-device build, replace `DEVELOPMENT_TEAM: YOUR_TEAM_ID` in `project.yml`
with your own Team ID — see
[On-device builds](../../../README.md#on-device-builds) in the root README.

```sh
rake ios:net:device:all
```

On a real device, tapping FETCH (or the boot-time auto-fetch) logs
`handshake OK, response received (N bytes)` and `status: HTTP/1.1 200 OK`.

## Individual rake tasks

Each pipeline step is also exposed as its own task.

- `rake ios:net:lib` — cross-build `libmruby.a` (Simulator) with picoruby-net-http +
  the socket/mbedTLS/rng darwin ports, stage under `Vendor/`
- `rake ios:net:gen` — generate `Networking.xcodeproj` from `project.yml`
- `rake ios:net:build` — build the app for the Simulator
- `rake ios:net:run` — boot a Simulator, install, launch
- `rake ios:net:device:lib` — cross-build `libmruby.a` for the device SDK
- `rake ios:net:device:build` — build signed for a connected device
- `rake ios:net:device:run` — install and launch on the connected device
- `rake ios:net:device:all` — full device pipeline: lib -> gen -> build -> run
