import CoreImage
import Foundation
import ImageIO

/// デモザイク前のベイヤー画像と、現像に要るカメラごとの値。
/// どこから読んだか(LibRaw か自前の NEF 解析か)に関係なく、ここから先の現像は同じ:
/// 黒レベル → ホワイトバランス → デモザイク → 色の変換 → 向き。
/// RawLab エンジン(LibRaw で読む)とネイティブデコーダー(自前で読む)が共有する。
struct BayerMosaic {
    let width: Int
    let height: Int
    /// 2×2 の色配置 [左上, 右上, 左下, 右下]。0=R 1=G 2=B
    let pattern: [Int]
    /// 各画素の生の値(見える範囲だけ、黒レベルを引く前)
    let raw: [UInt16]
    /// 画素ごとの黒レベル(2×2 の位置ごと + 模様)
    let blackForPosition: [Float]
    let blackPattern: (rows: Int, cols: Int, values: [Float])
    let white: Float
    /// 緑を 1 にそろえた WB 係数(撮影時 / 昼光)
    let asShotMul: [Float]
    let daylightMul: [Float]
    /// カメラの RGB(ホワイトバランス後)→ リニア sRGB。3×3 を行ごとに並べたもの
    let matrix: [Float]
    let orientation: CGImagePropertyOrientation?

    /// リニア・デモザイク済み・WB 適用済みのリニア sRGB の画像にする
    func develop(_ options: DecodeOptions) -> CIImage {
        let reconstruct = options.highlight == .reconstruct
        let wb = whiteBalance(asShot: options.applyAsShotWB)
        let plane = normalizedPlane(wb: wb, clipAfterWB: !reconstruct)
        // 補間で飽和の値を超えないよう、色ごとに上限をかける(復元するときの飽和の値は wb[c])。
        // 強い境目の近くで Malvar-He-Cutler が行き過ぎた値を出しても、色の付いた斑点にならない
        let upper: [Float] = reconstruct ? wb : [1, 1, 1]
        var rgb: [Float]
        var w = width, h = height
        if options.halfSize {
            (rgb, w, h) = Demosaic.superpixel(plane, width, height, pattern)
        } else if options.demosaic == .linear {
            rgb = Demosaic.bilinear(plane, width, height, pattern, upper: upper)
        } else {
            rgb = Demosaic.malvar(plane, width, height, pattern, upper: upper)
        }
        if reconstruct {
            HighlightReconstruction.reconstruct(&rgb, w, h, clip: wb)
        }
        convertToSRGB(&rgb)

        let data = rgb.withUnsafeBufferPointer { Data(buffer: $0) }
        var image = CIImage(bitmapData: data, bytesPerRow: w * 16,
                            size: CGSize(width: w, height: h), format: .RGBAf,
                            colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB))
        if let o = orientation { image = image.oriented(o) }
        return image
    }

    func whiteBalance(asShot: Bool) -> [Float] { asShot ? asShotMul : daylightMul }

    /// 黒レベルを引き、白レベルで 0〜1 にし、ホワイトバランスをかけた 1 枚の面。
    /// clipAfterWB なら WB 後に 1 で頭打ち(白飛びは白)、そうでなければ WB 前に 1 で頭打ち
    /// (色ごとの飽和の値が wb[c] になり、白飛びの復元で使える)
    func normalizedPlane(wb: [Float], clipAfterWB: Bool) -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        let pat = pattern, blackPos = blackForPosition, bp = blackPattern, white = white, w = width
        raw.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    for x in 0..<w {
                        let pos = (y & 1) * 2 + (x & 1)
                        var black = blackPos[pos]
                        if bp.rows > 0 { black += bp.values[(y % bp.rows) * bp.cols + x % bp.cols] }
                        let v = (Float(src[y * w + x]) - black) / max(white - black, 1)
                        dst[y * w + x] = clipAfterWB
                            ? min(max(v * wb[pat[pos]], 0), 1)
                            : min(max(v, 0), 1) * wb[pat[pos]]
                    }
                }
            }
        }
        return out
    }

    /// カメラの RGB → リニア sRGB(RGBA の並び。A はそのまま)
    func convertToSRGB(_ rgba: inout [Float]) {
        Self.apply(matrix, to: &rgba)
    }

    /// RGBA の並びの各画素に 3×3 の行列をかける(A はそのまま)
    static func apply(_ m: [Float], to rgba: inout [Float]) {
        let count = rgba.count / 4
        rgba.withUnsafeMutableBufferPointer { p in
            DispatchQueue.concurrentPerform(iterations: max(1, count / 65536 + 1)) { chunk in
                let lo = chunk * 65536, hi = min(count, lo + 65536)
                guard lo < hi else { return }
                for i in lo..<hi {
                    let r = p[i * 4], g = p[i * 4 + 1], b = p[i * 4 + 2]
                    p[i * 4] = m[0] * r + m[1] * g + m[2] * b
                    p[i * 4 + 1] = m[3] * r + m[4] * g + m[5] * b
                    p[i * 4 + 2] = m[6] * r + m[7] * g + m[8] * b
                }
            }
        }
    }
}
