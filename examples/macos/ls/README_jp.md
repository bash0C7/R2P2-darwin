# ls — macOS ホスト向け単一バイナリのデモ

PicoRuby で書いた、カレントディレクトリの `ls` 風リスティングです。Ruby
スクリプトを 1 つの自己完結・可搬な実行ファイルに埋め込む `rake macos:single`
のデモスクリプトです:

```sh
rake macos:single APP=examples/macos/ls/ls.rb   # -> ./build/host/bin/ls
./build/host/bin/ls                             # 自己完結バイナリ 1 つ
```

スクリプトはホスト gembox が提供する機能 — `Dir.entries`、`File` のクラス
メソッド、`sprintf`、`Array` の sort/reject、`rescue` — を一通り使っています。
[ルート README の macOS ホスト節](../../../README_jp.md#macos-ホスト) も参照
してください。
