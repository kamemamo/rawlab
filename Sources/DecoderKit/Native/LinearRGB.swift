import CoreImage
import Foundation
import ImageIO

/// デモザイク済みのカメラの RGB(DNG の LinearRaw。iPhone の ProRAW など)と、現像に要る値。
/// ベイヤー配列の BayerMosaic と同じ順で現像する(デモザイクだけがない):
/// 黒・白レベル → ホワイトバランス → 白飛びの復元 → 色の変換 → 明るさの基準 → 向き
struct LinearRGB {
    let width: Int
    let height: Int
    /// 画素ごとに R, G, B の生の値(黒レベルを引く前)
    let raw: [UInt16]
    /// 色ごとの黒レベル
    let black: [Float]
    let white: Float
    /// 緑を 1 にそろえた WB 係数(撮影時 / 昼光)
    let asShotMul: [Float]
    let daylightMul: [Float]
    /// カメラの RGB(ホワイトバランス後)→ リニア sRGB
    let matrix: [Float]
    /// 明るさの倍率(BaselineExposure の 2 のべき乗)
    let exposureGain: Float
    let orientation: CGImagePropertyOrientation?

    func develop(_ options: DecodeOptions) -> (image: CIImage, saturation: SensorSaturation, dark: DarkInfo) {
        // 強さ 0 は切り捨てと同じ処理にする(途中の頭打ちの位置が違うと、縁の補間がわずかに変わるため)
        let reconstruct = options.highlight == .reconstruct && options.highlightStrength > 0
        let wb = options.applyAsShotWB ? asShotMul : daylightMul
        let step = options.halfSize ? 2 : 1
        let w = width / step, h = height / step
        var rgba = [Float](repeating: 1, count: w * h * 4)
        let black = black, white = white, srcWidth = width
        // 白レベルより手前で飽和していれば、その値を 1 にそろえる
        let levels = saturationLevels()
        let scale = 1 / max(levels.min() ?? 1, 0.5)
        let limits = levels.map { $0 * SensorSaturationDetect.threshold }
        let lower: Float = options.keepBelowBlack ? -0.02 : 0
        var bits = [UInt8](repeating: 0, count: w * h)
        raw.withUnsafeBufferPointer { src in
          bits.withUnsafeMutableBufferPointer { sat in
            rgba.withUnsafeMutableBufferPointer { dst in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        var b: UInt8 = 0
                        for c in 0..<3 {
                            // 半分の大きさのときは 2×2 の平均
                            var sum: Float = 0, peak: Float = 0
                            for dy in 0..<step {
                                for dx in 0..<step {
                                    let r = Float(src[((y * step + dy) * srcWidth + x * step + dx) * 3 + c])
                                    sum += r
                                    peak = max(peak, r)
                                }
                            }
                            let range = max(white - black[c], 1)
                            if (peak - black[c]) / range >= limits[c] { b |= 1 << c }
                            let v = (sum / Float(step * step) - black[c]) / range * scale
                            let clipped = min(max(v, lower), 1)
                            // 復元するときは WB 前に頭打ち(色ごとの飽和の値が wb[c] になる)
                            dst[(y * w + x) * 4 + c] = reconstruct ? clipped * wb[c] : min(clipped * wb[c], 1)
                        }
                        sat[y * w + x] = b
                    }
                }
            }
          }
        }
        if reconstruct {
            HighlightReconstruction.reconstruct(&rgba, w, h, clip: wb, strength: Float(options.highlightStrength))
        }
        BayerMosaic.apply(matrix.map { $0 * exposureGain }, to: &rgba)
        var info = DarkInfo(declaredBlack: Double(black.reduce(0, +) / 3))
        if options.shadowNoiseReduction > 0 {
            info.noiseAtBlack = ShadowDenoise.apply(&rgba, w, h, strength: Float(options.shadowNoiseReduction),
                                                    halfSize: options.halfSize).map(Double.init)
        }

        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        var image = CIImage(bitmapData: data, bytesPerRow: w * 16,
                            size: CGSize(width: w, height: h), format: .RGBAf,
                            colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB))
        if let o = orientation { image = image.oriented(o) }
        let saturation = SensorSaturationDetect.makeSaturation(
            bits: bits, width: w, height: h, outputSize: CGSize(width: w, height: h), orientation: orientation)
        return (image, saturation, info)
    }

    /// 色ごとのセンサーの飽和の値(白レベル = 1)
    func saturationLevels() -> [Float] {
        let w = width, black = black, range = black.map { max(white - $0, 1) }
        return raw.withUnsafeBufferPointer { src in
            SensorSaturationDetect.levels(rows: height) { y, body in
                for x in 0..<w {
                    for c in 0..<3 { body(c, (Float(src[(y * w + x) * 3 + c]) - black[c]) / range[c]) }
                }
            }
        }
    }
}
