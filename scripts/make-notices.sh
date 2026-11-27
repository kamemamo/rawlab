#!/bin/zsh
# THIRD_PARTY_NOTICES.md を作り直す(rawler-ffi が実際に使っている Rust の部品も一覧にする)
set -euo pipefail
cd "$(dirname "$0")/.."
{
cat <<'HEAD'
# サードパーティのライセンス

RawLab は次のソフトウェアを使っています。各ライセンスの全文はアプリ内の
`RawLab.app/Contents/Resources/Licenses/` にあります。

## アプリに同梱しているライブラリ

| ライブラリ | ライセンス | 入手先 |
|---|---|---|
| LibRaw 0.22 | LGPL-2.1 または CDDL-1.0(LGPL-2.1 を選択) | https://www.libraw.org/ |
| rawler 0.8(Rust、静的リンク) | LGPL-2.1 | https://github.com/dnglab/dnglab |
| LLVM OpenMP (libomp) | MIT(Homebrew の表記。全文は同梱の libomp-LICENSE.txt) | https://openmp.llvm.org/ |
| libjpeg-turbo | IJG / BSD-3-Clause / Zlib | https://libjpeg-turbo.org/ |
| Little CMS (lcms2) | MIT | https://www.littlecms.com/ |

This software is based in part on the work of the Independent JPEG Group.

### LGPL について

LibRaw と rawler は LGPL-2.1 です。RawLab のソースコード(rawler と組み合わせて
作り直すために必要なもの一式)は https://github.com/kamemamo/rawlab で公開しています
(RawLab 自体のコードは MIT ライセンス)。同梱の LibRaw は
`Contents/Frameworks/libraw_r.25.dylib` を差し替えて使うこともできます。

## rawler が使っている Rust の部品

HEAD
echo '| 部品 | 版 | ライセンス |'
echo '|---|---|---|'
(cd rawler-ffi && cargo tree -e normal --prefix none --format '{p} {l}' 2>/dev/null) \
  | sed -E 's/ \(\*\)//; s/ \(proc-macro\)//' | sort -u \
  | awk '{name=$1; ver=$2; $1=""; $2=""; sub(/^  /, ""); printf "| %s | %s | %s |\n", name, ver, $0}' \
  | grep -v '^| rawler-ffi '
} > THIRD_PARTY_NOTICES.md
echo "✓ THIRD_PARTY_NOTICES.md ($(grep -c '^| ' THIRD_PARTY_NOTICES.md) 行)"
