# RawLab

自分用の RAW 現像アプリ(macOS)。デコーダーを切り替えて比較できる。

## 必要なもの
- Xcode / Swift 6
- `brew install libraw`
- Rust(rawler 用)。初回は `cd rawler-ffi && cargo build --release`

## 対応している RAW

| メーカー | 拡張子 | 確認済みの機種(raw.pixls.us のサンプル) |
|---|---|---|
| Nikon | NEF / NRW | D5 |
| Canon | CR3 / CR2 / CRW | EOS R5(CRAW)、EOS 5D Mark IV |
| Sony | ARW / SRF / SR2 | α7 III(非圧縮 14bit) |
| OM System / Olympus | ORF | E-M1 Mark II |
| Fujifilm | RAF | X-T3(X-Trans) |
| Panasonic / Leica | RW2 / RAW / RWL | LUMIX S5 |
| Pentax / Ricoh | PEF / PTX | K-1 |
| Samsung | SRW | NX1(Core Image は非対応、LibRaw / rawler で開く) |
| Leica ほか | DNG | M10 |
| Hasselblad / Phase One / Sigma / Minolta / Kodak など | 3FR / FFF / IIQ / MOS / MEF / X3F / MRW / DCR / KDC / ERF | 未確認(デコーダーは対応) |

開けないデコーダーがあっても、自動で次のデコーダーに切り替えて開く。

## ライブラリ

- **RAW**: 登録したフォルダ(サブフォルダ含む)を読むだけ。移動・変更・書き込みは一切しない
- **現像データ**: `~/Pictures/RawLab Library/catalog.sqlite` にまとめて保存。1 枚の RAW に複数の現像バージョンを持てる
- **書き出し**: `~/Pictures/RawLab Export/<年>/<撮影日>/<撮影日時>_<RAW名>[_<バージョン名>].jpg`(書き出し先は変更可)。履歴を残し、書き出し後に編集すると「要再書き出し」になる
- RAW を移動・改名しても、移動先フォルダを登録して再スキャンすれば指紋(サイズ + 先頭 1MB の SHA-256)で照合して現像データを引き継ぐ
- 旧方式のサイドカー(`<RAW>.rawlab.json`)は初回登録時に取り込む(ファイルは消さない)
- 環境変数 `RAWLAB_LIBRARY` でライブラリの場所を変えられる(テスト用)

## 使い方

```sh
# アプリ(.app を作って起動)。--args でフォルダを渡すとライブラリに登録
./scripts/make-app.sh && open build/RawLab.app

# 開発中はこちらでも可
swift run RawLabApp samples

# CLI
swift run rawlab decoders
swift run rawlab info samples/D5_sample.NEF
swift run rawlab develop samples/*.NEF --decoder libraw --ev 0.3 --out out
swift run rawlab compare samples/D5_sample.NEF --crop 800 --nr 0.5

# ライブラリ
swift run rawlab library add /Volumes/Photo/2026
swift run rawlab library photos
swift run rawlab library export /Volumes/Photo/2026/DSC_0001.NEF
```

## 構成
| 場所 | 役割 |
|---|---|
| `Sources/DecoderKit/RawDecoder.swift` | デコーダー共通の契約(リニア・デモザイク済み CIImage を返す) |
| `Sources/DecoderKit/CoreImageDecoder.swift` | macOS 標準 CIRAWFilter |
| `Sources/DecoderKit/LibRawDecoder.swift` | LibRaw C API |
| `Sources/DecoderKit/RawlerDecoder.swift` + `rawler-ffi/` | Rust の rawler(C ABI 経由、PPG デモザイク固定) |
| `Sources/DecoderKit/DecoderRegistry.swift` | デコーダー一覧とフォールバック |
| `Sources/DecoderKit/DevelopPipeline.swift` | 共通の現像処理・書き出し・サムネイル |
| `Sources/DecoderKit/Sidecar.swift` | 旧方式のサイドカー(取り込み専用) |
| `Sources/LibraryKit/` | カタログ(SQLite)、フォルダスキャン、指紋照合、バージョン、書き出し履歴 |
| `Sources/rawlab-cli` | CLI |
| `Sources/RawLabApp` | SwiftUI アプリ |

デコーダーを足すときは `RawDecoder` を実装して `DecoderRegistry.all` に追加する。
