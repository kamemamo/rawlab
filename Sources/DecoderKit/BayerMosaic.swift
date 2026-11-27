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
    /// 行ごとの黒の補正(遮光画素で測った値。生の値で、blackForPosition に足す)
    var rowBlack: [Float]? = nil
    /// 測った値(表示用)。デコーダーが埋める
    var darkInfo = DarkInfo(declaredBlack: 0)

    /// リニア・デモザイク済み・WB 適用済みのリニア sRGB の画像と、センサーの飽和の地図にする
    func develop(_ options: DecodeOptions) -> (image: CIImage, saturation: SensorSaturation, dark: DarkInfo) {
        // 強さ 0 は切り捨てと同じ処理にする(途中の頭打ちの位置が違うと、縁の補間がわずかに変わるため)
        let reconstruct = options.highlight == .reconstruct && options.highlightStrength > 0
        let wb = whiteBalance(asShot: options.applyAsShotWB)
        // 白レベルより手前で飽和している機種では、その値を 1 にそろえる
        // (そろえないと、飽和した緑が 1 に届かず、白飛びがマゼンタになる)
        let levels = saturationLevels()
        let scale = 1 / max(levels.min() ?? 1, 0.5)
        // 黒より下の値を残すときの下限(白 = 1 に対して。暗部のノイズには十分で、
        // デモザイクが強い境目で行き過ぎた値は抑えられる大きさ)
        let lower: Float = options.keepBelowBlack ? -0.02 : 0
        let plane = normalizedPlane(wb: wb, clipAfterWB: !reconstruct, scale: scale, lower: lower)
        // 補間で飽和の値を超えないよう、色ごとに上限をかける(復元するときの飽和の値は wb[c])。
        // 強い境目の近くで Malvar-He-Cutler が行き過ぎた値を出しても、色の付いた斑点にならない
        let upper: [Float] = reconstruct ? wb : [1, 1, 1]
        var rgb: [Float]
        var w = width, h = height
        if options.halfSize {
            (rgb, w, h) = Demosaic.superpixel(plane, width, height, pattern)
        } else if options.demosaic == .linear {
            rgb = Demosaic.bilinear(plane, width, height, pattern, upper: upper, lower: lower)
        } else {
            rgb = Demosaic.malvar(plane, width, height, pattern, upper: upper, lower: lower)
        }
        if reconstruct {
            HighlightReconstruction.reconstruct(&rgb, w, h, clip: wb, strength: Float(options.highlightStrength))
        }
        convertToSRGB(&rgb)
        var info = darkInfo
        if info.declaredBlack == 0 {
            info.declaredBlack = Double(blackForPosition.reduce(0, +) / 4)
                + (blackPattern.values.isEmpty ? 0 : Double(blackPattern.values.reduce(0, +)) / Double(blackPattern.values.count))
        }
        if options.shadowNoiseReduction > 0 {
            info.noiseAtBlack = ShadowDenoise.apply(&rgb, w, h, strength: Float(options.shadowNoiseReduction),
                                                    halfSize: options.halfSize).map(Double.init)
        }

        let data = rgb.withUnsafeBufferPointer { Data(buffer: $0) }
        var image = CIImage(bitmapData: data, bytesPerRow: w * 16,
                            size: CGSize(width: w, height: h), format: .RGBAf,
                            colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB))
        if let o = orientation { image = image.oriented(o) }
        let saturation = saturationMap(levels: levels, outputSize: CGSize(width: w, height: h))
        return (image, saturation, info)
    }

    /// 0〜1 に正規化した値(黒を引き、白で割る)
    @inline(__always)
    private func normalized(_ value: UInt16, x: Int, y: Int) -> Float {
        let pos = (y & 1) * 2 + (x & 1)
        var black = blackForPosition[pos]
        if let rowBlack { black += rowBlack[y] }
        if blackPattern.rows > 0 {
            black += blackPattern.values[(y % blackPattern.rows) * blackPattern.cols + x % blackPattern.cols]
        }
        return (Float(value) - black) / max(white - black, 1)
    }

    /// 色ごとのセンサーの飽和の値(白レベル = 1)
    func saturationLevels() -> [Float] {
        let w = width, pat = pattern
        return raw.withUnsafeBufferPointer { src in
            SensorSaturationDetect.levels(rows: height) { y, body in
                for x in 0..<w {
                    body(pat[(y & 1) * 2 + (x & 1)], normalized(src[y * w + x], x: x, y: y))
                }
            }
        }
    }

    /// 2×2 のブロックごとに、どの色が飽和したかの地図
    private func saturationMap(levels: [Float], outputSize: CGSize) -> SensorSaturation {
        let bw = width / 2, bh = height / 2, w = width, pat = pattern
        let limits = levels.map { $0 * SensorSaturationDetect.threshold }
        var bits = [UInt8](repeating: 0, count: bw * bh)
        raw.withUnsafeBufferPointer { src in
            bits.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: bh) { by in
                    for bx in 0..<bw {
                        var b: UInt8 = 0
                        for dy in 0..<2 {
                            for dx in 0..<2 {
                                let x = bx * 2 + dx, y = by * 2 + dy
                                let c = pat[dy * 2 + dx]
                                if normalized(src[y * w + x], x: x, y: y) >= limits[c] { b |= 1 << c }
                            }
                        }
                        out[by * bw + bx] = b
                    }
                }
            }
        }
        return SensorSaturationDetect.makeSaturation(bits: bits, width: bw, height: bh,
                                                     outputSize: outputSize, orientation: orientation)
    }

    func whiteBalance(asShot: Bool) -> [Float] { asShot ? asShotMul : daylightMul }

    /// 黒レベルを引き、白レベルで 0〜1 にし、ホワイトバランスをかけた 1 枚の面。
    /// clipAfterWB なら WB 後に 1 で頭打ち(白飛びは白)、そうでなければ WB 前に 1 で頭打ち
    /// (色ごとの飽和の値が wb[c] になり、白飛びの復元で使える)
    func normalizedPlane(wb: [Float], clipAfterWB: Bool, scale: Float = 1, lower: Float = 0) -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        let pat = pattern, blackPos = blackForPosition, bp = blackPattern, white = white, w = width
        let rows = rowBlack
        raw.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    let rowOffset = rows?[y] ?? 0
                    for x in 0..<w {
                        let pos = (y & 1) * 2 + (x & 1)
                        var black = blackPos[pos] + rowOffset
                        if bp.rows > 0 { black += bp.values[(y % bp.rows) * bp.cols + x % bp.cols] }
                        let v = (Float(src[y * w + x]) - black) / max(white - black, 1) * scale
                        dst[y * w + x] = clipAfterWB
                            ? min(max(v * wb[pat[pos]], lower), 1)
                            : min(max(v, lower), 1) * wb[pat[pos]]
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
