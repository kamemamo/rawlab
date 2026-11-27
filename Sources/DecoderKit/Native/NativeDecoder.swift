import CoreImage
import Foundation
import ImageIO

/// 外部ライブラリに頼らない、完全に自前のデコーダー。
/// ファイルの解析(TIFF の IFD・EXIF・ニコンのメーカーノート)、ロスレス圧縮の展開、
/// 黒・白レベル、WB 係数、色の行列までを Swift で行い、
/// その先(WB → デモザイク → 色の変換)は RawLab エンジンと同じ処理(BayerMosaic)を通す。
///
/// - 対応: ニコンの NEF(圧縮・ロスレス圧縮・非圧縮)のうち、色の値を持っている機種(いまは D5)
/// - 未対応のものは開く前に `unsupportedReason` で理由を返す
public struct NativeDecoder: RawDecoder {
    public let id = "native"
    public let displayName = "RawLab ネイティブ"

    public init() {}

    public func unsupportedReason(_ url: URL) -> String? {
        guard ["nef", "nrw"].contains(url.pathExtension.lowercased()) else {
            return "ニコンの NEF のみ対応"
        }
        return Self.check(url)
    }

    public func decode(_ url: URL, options: DecodeOptions) throws -> DecodedImage {
        if let reason = unsupportedReason(url) { throw DecoderError.failed("\(displayName): \(reason)") }
        let start = Date()
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let nef = try NikonNEF(data: data)
        let mosaic = try Self.mosaic(nef, data: data)
        let image = mosaic.develop(options)
        return DecodedImage(image: image, metadata: Self.metadata(nef), decoderID: id,
                            options: options, decodeTime: Date().timeIntervalSince(start))
    }

    public func metadata(_ url: URL) throws -> RawMetadata {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        return Self.metadata(try NikonNEF(data: data))
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
            let data = try Data(contentsOf: url, options: .alwaysMapped)
            reason = unsupportedReason(try NikonNEF(data: data))
        } catch {
            reason = "NEF として読めません(\(error.localizedDescription))"
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
        guard nef.blackLevel != nil else { return "黒レベルがメーカーノートにないため未対応" }
        guard nef.asShotRB != nil else { return "撮影時の WB がメーカーノートにないため未対応" }
        return nil
    }

    // MARK: - NEF → モザイク

    private static func mosaic(_ nef: NikonNEF, data: Data) throws -> BayerMosaic {
        guard let camXYZ = CameraColor.matrices[nef.model.uppercased()],
              let color = CameraColor.conversion(cameraFromXYZ: camXYZ),
              let blackLevel = nef.blackLevel, let rb = nef.asShotRB
        else { throw DecoderError.failed("RawLab ネイティブ: \(unsupportedReason(nef) ?? "未対応")") }

        let raw = try nef.decode()

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
            width: nef.width, height: nef.height,
            pattern: pattern,
            raw: raw,
            blackForPosition: blackForPosition,
            blackPattern: (0, 0, []),
            white: Float((1 << nef.bitsPerSample) - 1),
            asShotMul: [Float(rb.r), 1, Float(rb.b)],
            daylightMul: color.daylight,
            matrix: color.matrix,
            orientation: CGImagePropertyOrientation(rawValue: UInt32(nef.orientation)).flatMap { $0 == .up ? nil : $0 })
    }

    // MARK: - メタデータ

    /// "NIKON D5" → "D5"(LibRaw と同じ表記にそろえる)
    private static func cleanModel(_ model: String) -> String {
        model.uppercased().hasPrefix("NIKON ") ? String(model.dropFirst(6)) : model
    }

    private static func metadata(_ nef: NikonNEF) -> RawMetadata {
        var meta = RawMetadata()
        meta.make = nef.make.uppercased().hasPrefix("NIKON") ? "Nikon" : nef.make
        meta.model = cleanModel(nef.model)
        let e = nef.exif
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
        let rotated = [5, 6, 7, 8].contains(nef.orientation)
        meta.width = rotated ? nef.height : nef.width
        meta.height = rotated ? nef.width : nef.height
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
