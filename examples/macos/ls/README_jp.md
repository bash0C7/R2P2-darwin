# ls — macOSホスト向け単一バイナリのデモ

English: [README.md](README.md)

PicoRubyで書いた、カレントディレクトリの`ls`風リスティングです。Rubyファイルを
1つの自己完結した実行ファイルに埋め込む`rake macos:single`のデモスクリプトです。

```sh
rake macos:single APP=examples/macos/ls/ls.rb   # -> ./build/host/bin/ls
./build/host/bin/ls
```

できあがるバイナリはVMとgemとスクリプトのバイトコードを抱えており、picorubyの
インストールも、隣に置く`.rb`ファイルも要りません。

iOSやwatchOSのexampleと違い、ここにアプリもCブリッジもありません。picorubyは
macOS上でネイティブに動くので、ホストビルドが直接実行ファイルを産みます。
[macOSホスト](../../../README_jp.md#macosホスト)を参照してください。

## このスクリプトが触る範囲

`ls.rb`はhello worldより少し広めに書いてあります。走り切ったことがホスト側の
gem集合について何かを語るようにするためです。

- `Dir.entries`と`Array#reject` / `#sort` / `#each`
- `File.symlink?`・`File.directory?`・`File.file?`・`File.size`・
  `File.expand_path`
- 幅と精度の指定を伴う`sprintf`
- メソッド定義、`while`、三項演算子、サイズを読めないエントリ向けのインライン
  `rescue`によるフォールバック

`rake macos:single`は既定でスクリプトのbasenameをバイナリ名にします。`NAME=`で
上書きできます。スクリプトはgemの`mrblib`へコンパイルされるので、`ls.rb`を書き換えて
タスクを再実行すればバイナリも作り直されます。
