# RawLab

自分用の RAW 現像アプリ(macOS)。デコーダーを切り替えて比較できる。

## 必要なもの
- Xcode / Swift 6
- `brew install libraw`
- Rust(rawler 用)。初回は `cd rawler-ffi && cargo build --release`

## 使い方

```sh
# アプリ(.app を作って起動)
./scripts/make-app.sh && open build/RawLab.app --args "$PWD/samples"

# 開発中はこちらでも可
swift run RawLabApp samples

# CLI
swift run rawlab decoders
swift run rawlab info samples/D5_sample.NEF
swift run rawlab develop samples/*.NEF --decoder libraw --ev 0.3 --out out
swift run rawlab compare samples/D5_sample.NEF --crop 800 --nr 0.5
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
| `Sources/DecoderKit/Sidecar.swift` | `<RAW>.rawlab.json` に編集内容を保存 |
| `Sources/rawlab-cli` | CLI |
| `Sources/RawLabApp` | SwiftUI アプリ |

デコーダーを足すときは `RawDecoder` を実装して `DecoderRegistry.all` に追加する。
