# networking — HTTP and TLS from Ruby

日本語版: [README_jp.md](README_jp.md)

An HTTPS GET where the whole round-trip is PicoRuby. `app.rb` calls `Net::HTTP`
from picoruby's `picoruby-net-http` gem on top of `picoruby-socket`. On iOS,
`picoruby-socket`'s darwin port opens a raw BSD socket and runs the TLS
handshake through mbedTLS, seeded by the `picoruby-mbedtls` and `picoruby-rng`
darwin entropy ports, which draw randomness from `SecRandomCopyBytes`.

No OpenSSL is involved, and no Apple URL-loading API — no `URLSession`, no
`CFNetwork`. App Transport Security governs only those APIs, so it does not
apply here: this app's TLS is PicoRuby's own, running on the device.

## How it works

The FETCH button drives one call chain from SwiftUI down to mbedTLS. Every layer
below the bridge is either Ruby or picoruby-socket's C.

```
[SwiftUI FETCH button]
  --VMExecutor.shared.call("fetch")-->  $app (NetApp, Ruby)
    --> Net::HTTP.new(HOST, 443).get(PATH)   picoruby-net-http (Ruby)
    --> SSLSocket.open(host, port, ctx)      picoruby-socket (mruby glue)
    --> ports/darwin/ssl_socket.c            raw BSD socket + mbedTLS handshake
    --> picoruby-mbedtls darwin port         entropy from SecRandomCopyBytes
```

`VMExecutor` boots the VM once on appear — the persistent-VM shape shared by
every example except `repl` — and invokes `call("fetch")` as soon as `vm_open`
returns. That makes the result readable from
`xcrun devicectl device process launch --console` without a manual tap, since
the log lines are mirrored to `NSLog`. The FETCH button re-runs the request
interactively.

`app.rb` ships as a plain-text resource and is compiled at launch by the prism
compiler inside the app. Change `HOST` or `PATH`, reinstall, and the request
changes with no rebuild of `libmruby.a` or of the Swift layer. A successful
response means the mbedTLS handshake completed on iOS using the darwin entropy
port, driven entirely by that Ruby file.

### Certificate verification is deliberately off

`app.rb` sets `http.verify_mode = SSLContext::VERIFY_NONE`. iOS ships no PEM CA
bundle for mbedTLS to verify against, so the handshake completes but the server
certificate is not validated. This example demonstrates connectivity and a
handshake, not a trust decision.

To verify for real, bundle a CA PEM as an app resource and hand it to the
context — `SSLContext#set_ca_pem` takes the PEM contents, and `#ca_file=` reads
them from a path.

## Gem set

`build_config/r2p2-picoruby-ios-net-{sim,device}.rb` builds the same full-REPL
gembox set as [repl](../repl/README.md) — `mruby-posix` + `core` + `stdlib` +
`shell` — plus `picoruby-net-http`. So `app.rb` here has the whole Ruby surface
to work with, not the reduced one the BLE and sensor examples run on.

## Dependencies

This example needs a `vendor/picoruby` that carries `picoruby-socket`'s darwin
port. The default fetch (`bash0C7/picoruby`, branch `port-darwin`) includes it —
see [Vendor source](../../../README.md#vendor-source). Upstream
`picoruby/picoruby` has only the posix port, whose TLS links OpenSSL, which iOS
does not ship.

## Build and run

Prerequisites: the full `Xcode.app`, the iOS SDK, and `xcodegen`. `rake check`
verifies them.

### Simulator

```sh
rake ios:net:all      # lib -> gen -> build -> run
```

### Device

A real TLS handshake over the device's own network stack. Before the first
on-device build, replace `DEVELOPMENT_TEAM: YOUR_TEAM_ID` in `project.yml` with
your own Team ID — see
[Running on a device](../../../README.md#running-on-a-device).

```sh
rake ios:net:device:all
```

On success the log shows `handshake OK, response received (N bytes)` followed by
`status: HTTP/1.1 200 OK`.

## Individual tasks

Each pipeline step is also its own task.

| Task | What it does |
|---|---|
| `rake ios:net:lib` | cross-build `libmruby.a` for the Simulator SDK, stage under `Vendor/` |
| `rake ios:net:gen` | generate `Networking.xcodeproj` from `project.yml` |
| `rake ios:net:build` | build for the Simulator |
| `rake ios:net:run` | boot a Simulator, install, launch |
| `rake ios:net:observe` | launch repeatedly on a pinned Simulator and classify each run |
| `rake ios:net:device:lib` | cross-build `libmruby.a` for the device SDK |
| `rake ios:net:device:check` | link for a generic device without signing (no hardware needed) |
| `rake ios:net:device:build` | build signed for a connected device |
| `rake ios:net:device:run` | install and launch on the connected device |
| `rake ios:net:device:all` | the full device pipeline |
