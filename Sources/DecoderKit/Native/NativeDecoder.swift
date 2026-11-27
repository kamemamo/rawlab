import CoreImage
import Foundation
import ImageIO

/// 外部ライブラリに頼らない、完全に自前のデコーダー。
/// ファイルの解析(TIFF の IFD・EXIF・ニコンのメーカーノート・DNG のタグ)、圧縮の展開、
/// 黒・白レベル、WB 係数、色の行列までを Swift で行い、
/// その先(WB → デモザイク → 色の変換)は RawLab エンジンと同じ処理(BayerMosaic)を通す。
///
/// - 対応: ニコンの NEF(圧縮・ロスレス圧縮・非圧縮)のうち、色の値を持っている機種(いまは D5・D800)
/// - 対応: DNG(ベイヤー配列と、デモザイク済みの RGB = iPhone の ProRAW など)。
///   非圧縮・ロスレス JPEG・JPEG XL(展開だけ macOS の ImageIO)。色の値はファイルの中にあるので機種を問わない
/// - 未対応のものは開く前に `unsupportedReason` で理由を返す
public struct NativeDecoder: RawDecoder {
    public let id = "native"
    public let displayName = "RawLab ネイティブ"

    public init() {}

    /// 読んだファイル(形式ごと)
    private enum Source {
        case nef(NikonNEF)
        case dng(DNGFile)

        init(_ url: URL) throws {
            let data = try Data(contentsOf: url, options: .alwaysMapped)
            switch url.pathExtension.lowercased() {
            case "dng": self = .dng(try DNGFile(data: data))
            case "nef", "nrw": self = .nef(try NikonNEF(data: data))
            default: throw DecoderError.failed("RawLab ネイティブ: \(NativeDecoder.formatsReason)")
            }
        }
    }

    private static let formatsReason = "ニコンの NEF と DNG のみ対応"

    public func unsupportedReason(_ url: URL) -> String? {
        guard ["nef", "nrw", "dng"].contains(url.pathExtension.lowercased()) else {
            return Self.formatsReason
        }
        return Self.check(url)
    }

    public func decode(_ url: URL, options: DecodeOptions) throws -> DecodedImage {
        if let reason = unsupportedReason(url) { throw DecoderError.failed("\(displayName): \(reason)") }
        let start = Date()
        let source = try Source(url)
        let image: CIImage
        switch source {
        case .nef(let nef): image = try Self.mosaic(nef).develop(options)
        case .dng(let dng) where dng.isLinearRaw: image = try Self.linear(dng).develop(options)
        case .dng(let dng): image = try Self.mosaic(dng).develop(options)
        }
        return DecodedImage(image: image, metadata: Self.metadata(source), decoderID: id,
                            options: options, decodeTime: Date().timeIntervalSince(start))
    }

    public func metadata(_ url: URL) throws -> RawMetadata {
        Self.metadata(try Source(url))
    }

    // MARK: - 対応しているかの判定(ファイルごとに覚えておく)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [URL: String?] = [:]

    private static func check(_ url: URL) -> String? {
        lock.lock()
        if let hit = cache[url] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let reason: String?
        do {
            switch try Source(url) {
            case .nef(let nef): reason = unsupportedReason(nef)
            case .dng(let dng): reason = dng.unsupportedReason
            }
        } catch {
            reason = "読めません(\(error.localizedDescription))"
        }
        lock.lock()
        cache[url] = reason
        lock.unlock()
        return reason
    }

    private static func unsupportedReason(_ nef: NikonNEF) -> String? {
        if let reason = nef.unsupportedReason { return reason }
        guard CameraColor.matrices[nef.model.uppercased()] != nil else {
            let supported = CameraColor.supportedModels.map(cleanModel).joined(separator: "・")
            return "\(cleanModel(nef.model)) の色の値を持っていないため未対応(対応: \(supported))"
        }
        guard nef.asShotRB != nil else { return "撮影時の WB がメーカーノートにないため未対応" }
        return nil
    }

    private static func orientation(_ tiffValue: Int) -> CGImagePropertyOrientation? {
        CGImagePropertyOrientation(rawValue: UInt32(tiffValue)).flatMap { $0 == .up ? nil : $0 }
    }

    // MARK: - NEF → モザイク

    private static func mosaic(_ nef: NikonNEF) throws -> BayerMosaic {
        guard let camXYZ = CameraColor.matrices[nef.model.uppercased()],
              let color = CameraColor.conversion(cameraFromXYZ: camXYZ.map { $0 / 10000 }),
              let rb = nef.asShotRB
        else { throw DecoderError.failed("RawLab ネイティブ: \(unsupportedReason(nef) ?? "未対応")") }

        var raw = try nef.decode()
        // 右端の使わない列を落とす(D800 など)
        var width = nef.width
        if let visible = CameraColor.visibleWidth[nef.model.uppercased()], visible < width {
            raw = (0..<nef.height).flatMap { y in raw[(y * width)..<(y * width + visible)] }
            width = visible
        }
        // 黒レベルがメーカーノートにない機種(D800 など)は 0(LibRaw も同じ)
        let blackLevel = nef.blackLevel ?? [0, 0, 0, 0]

        // 黒レベルは R, G(R の行), G(B の行), B の順。2×2 の位置ごとに割り当てる。
        // メーカーノートの値は 14bit の目盛りなので、12bit のファイルでは 1/4 にする
        // (D500 の 12bit ロスレスで 400 → 100。LibRaw も同じ)
        let black = blackLevel.map { $0 >> max(0, 14 - nef.bitsPerSample) }
        let pattern = nef.cfa.map { $0 == 3 ? 1 : $0 }
        let blackForPosition: [Float] = (0..<4).map { pos in
            switch pattern[pos] {
            case 0: Float(black[0])
            case 2: Float(black[3])
            default:
                // 同じ行に R があれば R の行の緑
                Float(pattern[(pos & 2) + (1 - (pos & 1))] == 0 ? black[1] : black[2])
            }
        }

        return BayerMosaic(
            width: width, height: nef.height,
            pattern: pattern,
            raw: raw,
            blackForPosition: blackForPosition,
            blackPattern: (0, 0, []),
            white: Float((1 << nef.bitsPerSample) - 1),
            asShotMul: [Float(rb.r), 1, Float(rb.b)],
            daylightMul: color.daylight,
            matrix: color.matrix,
            orientation: orientation(nef.orientation))
    }

    // MARK: - DNG → モザイク

    private static func mosaic(_ dng: DNGFile) throws -> BayerMosaic {
        guard dng.unsupportedReason == nil, let cfa = dng.cfa, let camXYZ = dng.colorMatrix,
              let color = CameraColor.conversion(cameraFromXYZ: camXYZ)
        else { throw DecoderError.failed("RawLab ネイティブ: \(dng.unsupportedReason ?? "色の行列を計算できません")") }

        let full = try dng.decode()
        // 使う範囲(ActiveArea)だけを取り出す。CFA と黒レベルの模様はこの左上が基準
        let a = dng.activeArea
        let w = a.right - a.left, h = a.bottom - a.top
        var raw = [UInt16](repeating: 0, count: w * h)
        full.withUnsafeBufferPointer { src in
            raw.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    dst.baseAddress!.advanced(by: y * w)
                        .update(from: src.baseAddress!.advanced(by: (y + a.top) * dng.rawWidth + a.left), count: w)
                }
            }
        }

        // 撮影時の WB: AsShotNeutral(カメラの RGB での白)の逆数を、緑 = 1 にそろえる
        let asShot = dng.asShotNeutral.map { n in n.map { Float(n[1] / $0) } } ?? color.daylight

        return BayerMosaic(
            width: w, height: h,
            pattern: cfa,
            raw: raw,
            blackForPosition: [0, 0, 0, 0],
            blackPattern: (dng.black.rows, dng.black.cols, dng.black.values.map(Float.init)),
            white: Float(dng.whiteLevel),
            asShotMul: asShot,
            daylightMul: color.daylight,
            matrix: color.matrix,
            orientation: orientation(dng.orientation))
    }

    // MARK: - デモザイク済みの DNG → リニア RGB

    private static func linear(_ dng: DNGFile) throws -> LinearRGB {
        guard dng.unsupportedReason == nil, let camXYZ = dng.colorMatrix,
              let color = CameraColor.conversion(cameraFromXYZ: camXYZ)
        else { throw DecoderError.failed("RawLab ネイティブ: \(dng.unsupportedReason ?? "色の行列を計算できません")") }

        let full = try dng.decode()
        let a = dng.activeArea
        let w = a.right - a.left, h = a.bottom - a.top
        var raw = [UInt16](repeating: 0, count: w * h * 3)
        full.withUnsafeBufferPointer { src in
            raw.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    dst.baseAddress!.advanced(by: y * w * 3)
                        .update(from: src.baseAddress!.advanced(by: ((y + a.top) * dng.rawWidth + a.left) * 3), count: w * 3)
                }
            }
        }
        // 黒レベルは色ごと(3 個)か、全部同じ(1 個)
        let b = dng.black.values
        let black: [Float] = b.count >= 3 ? b.prefix(3).map(Float.init) : Array(repeating: Float(b.first ?? 0), count: 3)
        let asShot = dng.asShotNeutral.map { n in n.map { Float(n[1] / $0) } } ?? color.daylight

        return LinearRGB(
            width: w, height: h, raw: raw, black: black,
            white: Float(dng.whiteLevel),
            asShotMul: asShot, daylightMul: color.daylight,
            matrix: color.matrix,
            exposureGain: Float(pow(2, dng.baselineExposure)),
            orientation: orientation(dng.orientation))
    }

    // MARK: - メタデータ

    /// "NIKON D5" → "D5"(LibRaw と同じ表記にそろえる)
    private static func cleanModel(_ model: String) -> String {
        model.uppercased().hasPrefix("NIKON ") ? String(model.dropFirst(6)) : model
    }

    private static func metadata(_ source: Source) -> RawMetadata {
        var meta = RawMetadata()
        let e: RawExif
        let size: (w: Int, h: Int)
        let orientation: Int
        switch source {
        case .nef(let nef):
            meta.make = nef.make.uppercased().hasPrefix("NIKON") ? "Nikon" : nef.make
            meta.model = cleanModel(nef.model)
            e = nef.exif
            size = (CameraColor.visibleWidth[nef.model.uppercased()].map { min($0, nef.width) } ?? nef.width, nef.height)
            orientation = nef.orientation
        case .dng(let dng):
            meta.make = dng.make
            meta.model = dng.model
            e = dng.exif
            size = (dng.activeArea.right - dng.activeArea.left, dng.activeArea.bottom - dng.activeArea.top)
            orientation = dng.orientation
        }
        meta.iso = e.iso
        meta.shutter = e.exposureTime
        meta.aperture = e.fNumber
        meta.focalLength = e.focalLength
        if let s = e.dateTimeOriginal {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            meta.captureDate = f.date(from: s)
        }
        if let lens = e.lensModel, !lens.isEmpty {
            meta.lens = lens
        } else if let l = e.nikonLens, l.count == 4, l[0] > 0 {
            // 例: 14-24mm f/2.8、24-120mm f/4
            func n(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
            let focal = l[0] == l[1] ? "\(n(l[0]))mm" : "\(n(l[0]))-\(n(l[1]))mm"
            let aperture = l[2] == l[3] ? "f/\(n(l[2]))" : "f/\(n(l[2]))-\(n(l[3]))"
            meta.lens = "\(focal) \(aperture)"
        }
        let rotated = [5, 6, 7, 8].contains(orientation)
        meta.width = rotated ? size.h : size.w
        meta.height = rotated ? size.w : size.h
        meta.pictureControl = e.pictureControl
        meta.activeDLighting = e.activeDLighting.map(adlName)
        return meta
    }

    private static func adlName(_ v: Int) -> String {
        switch v {
        case 0: "オフ"
        case 1: "弱め"
        case 3: "標準"
        case 5: "強め"
        case 7: "より強め"
        case 8...11: "より強め \(v - 7)"
        case 0xFFFF: "オート"
        default: "不明 (\(v))"
        }
    }
}
