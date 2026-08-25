# ls — a single-binary demo for the macOS host

日本語版: [README_jp.md](README_jp.md)

An `ls`-style listing of the current directory, written in PicoRuby. It is the
demo script for `rake macos:single`, which embeds a Ruby file into one
standalone executable:

```sh
rake macos:single APP=examples/macos/ls/ls.rb   # -> ./build/host/bin/ls
./build/host/bin/ls
```

The resulting binary carries the VM, the gems, and the script's bytecode; it
needs no picoruby installation and no `.rb` file beside it.

Unlike the iOS and watchOS examples, there is no app and no C bridge here.
picoruby runs natively on macOS, so the host build produces an executable
directly — see [macOS host](../../../README.md#macos-host).

## What the script exercises

`ls.rb` is deliberately a little broader than a hello world, so that a
successful run says something about the host gem set:

- `Dir.entries` and `Array#reject` / `#sort` / `#each`
- `File.symlink?`, `File.directory?`, `File.file?`, `File.size`,
  `File.expand_path`
- `sprintf` with width and precision specifiers
- method definitions, `while`, ternaries, and an inline `rescue` fallback for
  entries whose size cannot be read

`rake macos:single` names the binary after the script's basename by default;
`NAME=` overrides it. The script is compiled into the gem's `mrblib`, so the
binary is regenerated whenever you change `ls.rb` and re-run the task.
