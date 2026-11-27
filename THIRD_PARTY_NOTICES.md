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

| 部品 | 版 | ライセンス |
|---|---|---|
| addr2line | v0.27.1 | Apache-2.0 OR MIT |
| adler2 | v2.0.1 | 0BSD OR MIT OR Apache-2.0 |
| adler32 | v1.2.0 | Zlib |
| alloc-no-stdlib | v2.0.4 | BSD-3-Clause |
| alloc-stdlib | v0.2.4 | BSD-3-Clause |
| allocator-api2 | v0.2.21 | MIT OR Apache-2.0 |
| backtrace | v0.3.77 | MIT OR Apache-2.0 |
| bitstream-io | v4.10.0 | MIT/Apache-2.0 |
| brotli-decompressor | v5.0.3 | BSD-3-Clause/MIT |
| bytemuck | v1.25.2 | Zlib OR Apache-2.0 OR MIT |
| byteorder | v1.5.0 | Unlicense OR MIT |
| byteorder-lite | v0.1.0 | Unlicense OR MIT |
| cfg-if | v1.0.5 | MIT OR Apache-2.0 |
| chrono | v0.4.45 | MIT OR Apache-2.0 |
| core-foundation-sys | v0.8.7 | MIT OR Apache-2.0 |
| crc32fast | v1.5.6 | MIT OR Apache-2.0 |
| crossbeam-deque | v0.8.8 | MIT OR Apache-2.0 |
| crossbeam-epoch | v0.9.21 | MIT OR Apache-2.0 |
| crossbeam-utils | v0.8.23 | MIT OR Apache-2.0 |
| dary_heap | v0.3.9 | MIT OR Apache-2.0 |
| either | v1.19.0 | MIT OR Apache-2.0 |
| enumn | v0.1.14 | MIT OR Apache-2.0 |
| equivalent | v1.0.3 | Apache-2.0 OR MIT |
| foldhash | v0.2.0 | Zlib |
| getrandom | v0.4.3 | MIT OR Apache-2.0 |
| gimli | v0.34.0 | MIT OR Apache-2.0 |
| hashbrown | v0.16.1 | MIT OR Apache-2.0 |
| hashbrown | v0.17.2 | MIT OR Apache-2.0 |
| hex | v0.4.3 | MIT OR Apache-2.0 |
| iana-time-zone | v0.1.65 | MIT OR Apache-2.0 |
| image | v0.25.10 | MIT OR Apache-2.0 |
| indexmap | v2.14.2 | Apache-2.0 OR MIT |
| itertools | v0.14.0 | MIT OR Apache-2.0 |
| jxl-bitstream | v1.1.0 | MIT OR Apache-2.0 |
| jxl-coding | v1.0.1 | MIT OR Apache-2.0 |
| jxl-color | v0.11.0 | MIT OR Apache-2.0 |
| jxl-frame | v0.13.3 | MIT OR Apache-2.0 |
| jxl-grid | v0.6.2 | MIT OR Apache-2.0 |
| jxl-image | v0.13.0 | MIT OR Apache-2.0 |
| jxl-jbr | v0.2.1 | MIT OR Apache-2.0 |
| jxl-modular | v0.11.3 | MIT OR Apache-2.0 |
| jxl-oxide | v0.12.6 | MIT OR Apache-2.0 |
| jxl-oxide-common | v1.0.0 | MIT OR Apache-2.0 |
| jxl-render | v0.12.4 | MIT OR Apache-2.0 |
| jxl-threadpool | v1.0.0 | MIT OR Apache-2.0 |
| jxl-vardct | v0.11.1 | MIT OR Apache-2.0 |
| lazy_static | v1.5.1 | MIT OR Apache-2.0 |
| libc | v0.2.191 | MIT OR Apache-2.0 |
| libflate | v2.3.2 | MIT |
| libflate_lz77 | v2.3.0 | MIT |
| log | v0.4.35 | MIT OR Apache-2.0 |
| md5 | v0.8.1 | Apache-2.0 OR MIT |
| memchr | v2.8.3 | Unlicense OR MIT |
| memmap2 | v0.9.12 | MIT OR Apache-2.0 |
| miniz_oxide | v0.9.1 | MIT OR Zlib OR Apache-2.0 |
| moxcms | v0.8.1 | BSD-3-Clause OR Apache-2.0 |
| multiversion | v0.8.1 | MIT OR Apache-2.0 |
| multiversion-macros | v0.8.1 | MIT OR Apache-2.0 |
| no_std_io2 | v0.9.4 | Apache-2.0 OR MIT |
| num | v0.4.3 | MIT OR Apache-2.0 |
| num-bigint | v0.4.8 | MIT OR Apache-2.0 |
| num-complex | v0.4.6 | MIT OR Apache-2.0 |
| num-integer | v0.1.47 | MIT OR Apache-2.0 |
| num-iter | v0.1.46 | MIT OR Apache-2.0 |
| num-rational | v0.4.2 | MIT OR Apache-2.0 |
| num-traits | v0.2.19 | MIT OR Apache-2.0 |
| num_enum | v0.7.6 | BSD-3-Clause OR MIT OR Apache-2.0 |
| num_enum_derive | v0.7.6 | BSD-3-Clause OR MIT OR Apache-2.0 |
| object | v0.40.0 | Apache-2.0 OR MIT |
| once_cell | v1.21.4 | MIT OR Apache-2.0 |
| pin-project-lite | v0.2.18 | Apache-2.0 OR MIT |
| proc-macro-crate | v3.5.0 | MIT OR Apache-2.0 |
| proc-macro2 | v1.0.107 | MIT OR Apache-2.0 |
| pxfm | v0.1.30 | BSD-3-Clause OR Apache-2.0 |
| quote | v1.0.47 | MIT OR Apache-2.0 |
| rawler | v0.8.0 | LGPL-2.1 |
| rayon | v1.12.0 | MIT OR Apache-2.0 |
| rayon-core | v1.13.0 | MIT OR Apache-2.0 |
| rle-decode-fast | v1.0.3 | MIT OR Apache-2.0 |
| rustc-demangle | v0.1.28 | MIT/Apache-2.0 |
| rustversion | v1.0.23 | MIT OR Apache-2.0 |
| serde | v1.0.229 | MIT OR Apache-2.0 |
| serde_core | v1.0.229 | MIT OR Apache-2.0 |
| serde_derive | v1.0.229 | MIT OR Apache-2.0 |
| serde_spanned | v0.6.9 | MIT OR Apache-2.0 |
| syn | v2.0.119 | MIT OR Apache-2.0 |
| syn | v3.0.10 | MIT OR Apache-2.0 |
| target-features | v0.1.6 | MIT OR Apache-2.0 |
| thiserror | v2.0.21 | MIT OR Apache-2.0 |
| thiserror-impl | v2.0.21 | MIT OR Apache-2.0 |
| toml | v0.8.23 | MIT OR Apache-2.0 |
| toml_datetime | v0.6.11 | MIT OR Apache-2.0 |
| toml_datetime | v1.1.3+spec-1.1.0 | MIT OR Apache-2.0 |
| toml_edit | v0.22.27 | MIT OR Apache-2.0 |
| toml_edit | v0.25.21+spec-1.1.0 | MIT OR Apache-2.0 |
| toml_parser | v1.1.7+spec-1.1.0 | MIT OR Apache-2.0 |
| toml_write | v0.1.2 | MIT OR Apache-2.0 |
| tracing | v0.1.44 | MIT |
| tracing-core | v0.1.36 | MIT |
| unicode-ident | v1.0.27 | (MIT OR Apache-2.0) AND Unicode-3.0 |
| uuid | v1.29.3 | Apache-2.0 OR MIT |
| weezl | v0.1.12 | MIT OR Apache-2.0 |
| winnow | v0.7.15 | MIT |
| winnow | v1.0.5 | MIT |
| zerocopy | v0.8.66 | BSD-2-Clause OR Apache-2.0 OR MIT |
| zerocopy-derive | v0.8.66 | BSD-2-Clause OR Apache-2.0 OR MIT |
| zune-core | v0.5.3 | MIT OR Apache-2.0 OR Zlib |
| zune-jpeg | v0.5.15 | MIT OR Apache-2.0 OR Zlib |
