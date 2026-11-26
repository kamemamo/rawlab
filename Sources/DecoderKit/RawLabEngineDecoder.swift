import CLibRaw
import CoreImage
import Foundation
import ImageIO

/// RawLab 独自の現像エンジン。
/// LibRaw はファイルを読んでモザイクのままのセンサーデータとカメラごとの値を取り出すところまで。
/// そこから先(黒レベル → ホワイトバランス → デモザイク → 色の変換 → 向き)を自前で行う。
///
/// - 対応: 2×2 のベイヤー配列(RGGB / BGGR / GRBG / GBRG)
/// - 未対応: Fujifilm X-Trans、4 色センサー、モザイクでない DNG など(他のデコーダーで開く)
/// - デモザイク: `.linear` はバイリニア、それ以外は Malvar-He-Cutler(勾配補正付きの線形補間)
/// - 半分サイズ: 2×2 をそのまま 1 画素にまとめる(スーパーピクセル。補間しないので速い)
public struct RawLabEngineDecoder: RawDecoder {
    public let id = "rawlab"
    public let displayName = "RawLab エンジン"

    public init() {}

    public func metadata(_ url: URL) throws -> RawMetadata {
        try LibRawDecoder().metadata(url)
    }

    public func decode(_ url: URL, options: DecodeOptions) throws -> DecodedImage {
        let start = Date()
        guard let lr = libraw_init(0) else { throw DecoderError.failed("libraw_init 失敗") }
        defer { libraw_close(lr) }
        let opened = url.withUnsafeFileSystemRepresentation { libraw_open_file(lr, $0) }
        guard opened == 0 else { throw DecoderError.failed("RawLab エンジン: 開けません") }
        guard libraw_unpack(lr) == 0 else { throw DecoderError.failed("RawLab エンジン: 展開できません") }

        let sensor = try Sensor(lr)
        let reconstruct = options.highlight == .reconstruct
        let wb = sensor.whiteBalance(asShot: options.applyAsShotWB)
        let plane = sensor.normalizedPlane(wb: wb, clipAfterWB: !reconstruct)
        // 補間で飽和の値を超えないよう、色ごとに上限をかける(復元するときの飽和の値は wb[c])。
        // 強い境目の近くで Malvar-He-Cutler が行き過ぎた値を出しても、色の付いた斑点にならない
        let upper: [Float] = reconstruct ? wb : [1, 1, 1]
        var rgb: [Float]
        var width = sensor.width, height = sensor.height
        if options.halfSize {
            (rgb, width, height) = Demosaic.superpixel(plane, sensor.width, sensor.height, sensor.pattern)
        } else if options.demosaic == .linear {
            rgb = Demosaic.bilinear(plane, sensor.width, sensor.height, sensor.pattern, upper: upper)
        } else {
            rgb = Demosaic.malvar(plane, sensor.width, sensor.height, sensor.pattern, upper: upper)
        }
        if reconstruct {
            HighlightReconstruction.reconstruct(&rgb, width, height, clip: wb)
        }
        sensor.convertToSRGB(&rgb)

        let data = rgb.withUnsafeBufferPointer { Data(buffer: $0) }
        var image = CIImage(bitmapData: data, bytesPerRow: width * 16,
                            size: CGSize(width: width, height: height), format: .RGBAf,
                            colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB))
        if let o = sensor.orientation { image = image.oriented(o) }

        return DecodedImage(image: image, metadata: (try? metadata(url)) ?? RawMetadata(),
                            decoderID: id, options: options, decodeTime: Date().timeIntervalSince(start))
    }
}

// MARK: - センサーの情報(LibRaw から取り出す)

private struct Sensor {
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
    let asShotMul: [Float]
    let daylightMul: [Float]
    /// カメラの RGB(ホワイトバランス後)→ リニア sRGB
    let matrix: [Float]
    let orientation: CGImagePropertyOrientation?

    init(_ lr: UnsafeMutablePointer<libraw_data_t>) throws {
        let filters = lr.pointee.idata.filters
        guard let rawImage = lr.pointee.rawdata.raw_image else {
            throw DecoderError.failed("RawLab エンジン: モザイクの RAW ではないため未対応")
        }
        guard filters != 9 else { throw DecoderError.failed("RawLab エンジン: X-Trans センサーは未対応") }
        guard filters > 1000, lr.pointee.idata.colors == 3 else {
            throw DecoderError.failed("RawLab エンジン: このセンサー配列は未対応")
        }

        // 2×2 の色配置(3 は 2 つ目の緑なので 1 として扱う)。黒レベル用に生の番号も残す
        var rawColor = [Int](repeating: 0, count: 4)
        for r in 0..<2 {
            for c in 0..<2 { rawColor[r * 2 + c] = Int(libraw_COLOR(lr, Int32(r), Int32(c))) }
        }
        pattern = rawColor.map { $0 == 3 ? 1 : $0 }
        guard pattern.filter({ $0 == 0 }).count == 1, pattern.filter({ $0 == 2 }).count == 1 else {
            throw DecoderError.failed("RawLab エンジン: ベイヤー配列ではないため未対応")
        }

        let s = lr.pointee.sizes
        width = Int(s.width)
        height = Int(s.height)
        let top = Int(s.top_margin), left = Int(s.left_margin)
        let pitch = Int(s.raw_pitch) / 2
        // 見える範囲だけをコピー
        let w = Int(s.width), h = Int(s.height)
        var raw = [UInt16](repeating: 0, count: w * h)
        raw.withUnsafeMutableBufferPointer { dst in
            for y in 0..<h {
                let src = rawImage.advanced(by: (y + top) * pitch + left)
                dst.baseAddress!.advanced(by: y * w).update(from: src, count: w)
            }
        }
        self.raw = raw

        // 黒レベル: 全体 + 色ごと + 模様
        let color = lr.pointee.color
        // cblack(4104 要素)は大きすぎて Swift から直接読めないので、
        // すぐ後ろにある black の位置から逆算して読む(C の構造体では cblack の直後が black)
        let blackOffset = MemoryLayout<libraw_data_t>.offset(of: \libraw_data_t.color.black)!
        let cblackCount = 4104  // LIBRAW_CBLACK_SIZE
        let cblack = Array(UnsafeBufferPointer(
            start: (UnsafeRawPointer(lr) + blackOffset - cblackCount * 4).assumingMemoryBound(to: UInt32.self),
            count: cblackCount))
        let base = Float(color.black)
        blackForPosition = rawColor.map { base + Float(cblack[$0]) }
        let pr = Int(cblack[4]), pc = Int(cblack[5])
        if pr > 0, pc > 0, 6 + pr * pc <= cblack.count {
            blackPattern = (pr, pc, (0..<(pr * pc)).map { Float(cblack[6 + $0]) })
        } else {
            blackPattern = (0, 0, [])
        }
        white = Float(color.maximum)

        func mul(_ t: (Float, Float, Float, Float)) -> [Float]? {
            let m = [t.0, t.1, t.2]
            guard m.allSatisfy({ $0 > 0 }) else { return nil }
            return m.map { $0 / m[1] }  // 緑を 1 にそろえる
        }
        daylightMul = mul(color.pre_mul) ?? [1, 1, 1]
        asShotMul = mul(color.cam_mul) ?? daylightMul

        let m = withUnsafeBytes(of: color.rgb_cam) { Array($0.bindMemory(to: Float.self)) }  // 3×4
        matrix = (0..<3).flatMap { i in (0..<3).map { j in m[i * 4 + j] } }

        switch s.flip {
        case 3: orientation = .down
        case 5: orientation = .left
        case 6: orientation = .right
        default: orientation = nil
        }
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
        let m = matrix
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

// MARK: - デモザイク

enum Demosaic {
    /// 周りを 2 画素ずつ鏡写しで広げた面(端の処理をなくして中のループを単純にする)
    private static func padded(_ plane: [Float], _ w: Int, _ h: Int) -> (data: [Float], stride: Int) {
        let pw = w + 4, ph = h + 4
        var out = [Float](repeating: 0, count: pw * ph)
        func mirror(_ v: Int, _ n: Int) -> Int { v < 0 ? -v : (v >= n ? 2 * n - 2 - v : v) }
        for py in 0..<ph {
            let sy = mirror(py - 2, h)
            for px in 0..<pw {
                out[py * pw + px] = plane[sy * w + mirror(px - 2, w)]
            }
        }
        return (out, pw)
    }

    /// 2×2 を 1 画素に(緑は 2 つの平均)。補間しないので速くて正確、サイズは半分
    static func superpixel(_ plane: [Float], _ w: Int, _ h: Int, _ pat: [Int]) -> ([Float], Int, Int) {
        let ow = w / 2, oh = h / 2
        var out = [Float](repeating: 1, count: ow * oh * 4)
        plane.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                DispatchQueue.concurrentPerform(iterations: oh) { oy in
                    for ox in 0..<ow {
                        var rgb: (Float, Float, Float) = (0, 0, 0)
                        for k in 0..<4 {
                            let v = src[(oy * 2 + k / 2) * w + ox * 2 + k % 2]
                            switch pat[k] {
                            case 0: rgb.0 = v
                            case 2: rgb.2 = v
                            default: rgb.1 += v * 0.5
                            }
                        }
                        let o = (oy * ow + ox) * 4
                        dst[o] = rgb.0
                        dst[o + 1] = rgb.1
                        dst[o + 2] = rgb.2
                    }
                }
            }
        }
        return (out, ow, oh)
    }

    static func bilinear(_ plane: [Float], _ w: Int, _ h: Int, _ pat: [Int], upper: [Float] = [1, 1, 1]) -> [Float] {
        interpolate(plane, w, h, pat, upper) { p, s, color, rowColor in
            // p は中心を指すポインタ。s は 1 行分の幅
            let n = p[-s], so = p[s], we = p[-1], e = p[1]
            if color == 1 {
                let row = (we + e) * 0.5, col = (n + so) * 0.5
                return rowColor == 0 ? (row, p[0], col) : (col, p[0], row)
            }
            let g = (n + so + we + e) * 0.25
            let diag = (p[-s - 1] + p[-s + 1] + p[s - 1] + p[s + 1]) * 0.25
            return color == 0 ? (p[0], g, diag) : (diag, g, p[0])
        }
    }

    /// Malvar-He-Cutler (2004): 5×5 の線形補間に、同じ色の勾配で補正をかける
    static func malvar(_ plane: [Float], _ w: Int, _ h: Int, _ pat: [Int], upper: [Float] = [1, 1, 1]) -> [Float] {
        interpolate(plane, w, h, pat, upper) { p, s, color, rowColor in
            let c = p[0]
            let n = p[-s], so = p[s], we = p[-1], e = p[1]
            let nn = p[-2 * s], ss = p[2 * s], ww = p[-2], ee = p[2]
            let diag = p[-s - 1] + p[-s + 1] + p[s - 1] + p[s + 1]
            if color == 1 {
                // 緑の位置: 横にある色と縦にある色
                let row = (5 * c - diag - (ww + ee) + 0.5 * (nn + ss) + 4 * (we + e)) / 8
                let col = (5 * c - diag - (nn + ss) + 0.5 * (ww + ee) + 4 * (n + so)) / 8
                return rowColor == 0 ? (row, c, col) : (col, c, row)
            }
            let g = (4 * c + 2 * (n + so + we + e) - (nn + ss + ww + ee)) / 8
            let other = (6 * c + 2 * diag - 1.5 * (nn + ss + ww + ee)) / 8
            return color == 0 ? (c, g, other) : (other, g, c)
        }
    }

    /// 各画素について (R, G, B) を求めて RGBA に並べる共通部分
    private static func interpolate(
        _ plane: [Float], _ w: Int, _ h: Int, _ pat: [Int], _ upper: [Float],
        _ f: (UnsafePointer<Float>, Int, Int, Int) -> (Float, Float, Float)
    ) -> [Float] {
        let (pad, s) = padded(plane, w, h)
        var out = [Float](repeating: 1, count: w * h * 4)
        pad.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        let pos = (y & 1) * 2 + (x & 1)
                        let color = pat[pos]
                        // 緑の画素の左右にある色(R か B)
                        let rowColor = pat[(y & 1) * 2 + ((x + 1) & 1)]
                        let center = src.baseAddress!.advanced(by: (y + 2) * s + x + 2)
                        let (r, g, b) = f(center, s, color, rowColor)
                        let o = (y * w + x) * 4
                        dst[o] = min(max(r, 0), upper[0])
                        dst[o + 1] = min(max(g, 0), upper[1])
                        dst[o + 2] = min(max(b, 0), upper[2])
                    }
                }
            }
        }
        return out
    }
}
