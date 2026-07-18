# ls — a single-binary demo for the macOS host

An `ls`-like listing of the current directory, written in PicoRuby. It is the
demo script for `rake macos:single`, which embeds a Ruby script into one
standalone, portable executable:

```sh
rake macos:single APP=examples/macos/ls/ls.rb   # -> ./build/host/bin/ls
./build/host/bin/ls                             # one self-contained binary
```

The script exercises what the host gemboxes provide — `Dir.entries`, `File`
class methods, `sprintf`, `Array` sort/reject, `rescue`. See the
[macOS host section of the root README](../../../README.md#macos-host).
