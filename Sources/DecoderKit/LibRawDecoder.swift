import CLibRaw
import CoreGraphics
import CoreImage
import Foundation

/// LibRaw(Homebrew 版)を C API で呼ぶデコーダー。
/// 出力は 16bit・ガンマ 1.0(リニア)・Rec.2020 原色・自動明るさ補正なし。
public struct LibRawDecoder: RawDecoder {
    public let id = "libraw"
    public let displayName = "LibRaw \(String(cString: libraw_version()))"

    public init() {}

    public func decode(_ url: URL, options: DecodeOptions) throws -> DecodedImage {
        let start = Date()
        let raw = try open(url)
        defer { libraw_close(raw) }

        // 出力パラメータは dcraw_process の前に設定する
        raw.pointee.params.output_bps = 16
        raw.pointee.params.gamm.0 = 1.0          // リニア
        raw.pointee.params.gamm.1 = 1.0
        raw.pointee.params.no_auto_bright = 1    // 勝手に明るくしない
        raw.pointee.params.output_color = 8      // Rec.2020
        raw.pointee.params.highlight = 0         // 白飛びはクリップ
        raw.pointee.params.use_camera_wb = options.applyAsShotWB ? 1 : 0
        raw.pointee.params.use_auto_wb = 0
        raw.pointee.params.half_size = options.halfSize ? 1 : 0
        raw.pointee.params.user_qual = options.demosaic.librawQuality
        if options.noiseReduction > 0 {
            // ウェーブレット NR(dcraw -n 相当、目安 100〜1000)+ デモザイク前の FBDD
            raw.pointee.params.threshold = Float(options.noiseReduction * 800)
            raw.pointee.params.fbdd_noiserd = options.noiseReduction > 0.5 ? 2 : 1
        }

        try check(libraw_unpack(raw), "unpack")
        try check(libraw_dcraw_process(raw), "dcraw_process")

        var err: Int32 = 0
        guard let processed = libraw_dcraw_make_mem_image(raw, &err) else {
            throw DecoderError.failed("LibRaw make_mem_image 失敗: \(message(err))")
        }
        defer { libraw_dcraw_clear_mem(processed) }

        let image = try makeCIImage(processed)
        return DecodedImage(
            image: image,
            metadata: readMetadata(raw),
            decoderID: id,
            options: options,
            decodeTime: Date().timeIntervalSince(start)
        )
    }

    public func metadata(_ url: URL) throws -> RawMetadata {
        let raw = try open(url)
        defer { libraw_close(raw) }
        return readMetadata(raw)
    }

    // MARK: - private

    private func open(_ url: URL) throws -> UnsafeMutablePointer<libraw_data_t> {
        guard let raw = libraw_init(0) else { throw DecoderError.failed("libraw_init 失敗") }
        let result = url.withUnsafeFileSystemRepresentation { libraw_open_file(raw, $0) }
        if result != 0 {
            libraw_close(raw)
            throw DecoderError.failed("LibRaw で開けません: \(message(result))")
        }
        return raw
    }

    private func check(_ code: Int32, _ step: String) throws {
        if code != 0 { throw DecoderError.failed("LibRaw \(step) 失敗: \(message(code))") }
    }

    private func message(_ code: Int32) -> String {
        String(cString: libraw_strerror(code))
    }

    private func makeCIImage(_ img: UnsafeMutablePointer<libraw_processed_image_t>) throws -> CIImage {
        let width = Int(img.pointee.width)
        let height = Int(img.pointee.height)
        let colors = Int(img.pointee.colors)
        let bits = Int(img.pointee.bits)
        guard colors == 3, bits == 16 else {
            throw DecoderError.failed("想定外の出力形式: \(colors)ch / \(bits)bit")
        }
        // data は構造体末尾の可変長配列
        let offset = MemoryLayout<libraw_processed_image_t>.offset(of: \.data)!
        let base = UnsafeRawPointer(img).advanced(by: offset)
        let data = Data(bytes: base, count: Int(img.pointee.data_size))

        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.linearITUR_2020),
              let cgImage = CGImage(
                width: width, height: height,
                bitsPerComponent: 16, bitsPerPixel: 48,
                bytesPerRow: width * 6,
                space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue
                    | CGImageByteOrderInfo.order16Little.rawValue),
                provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent)
        else { throw DecoderError.failed("CGImage の作成に失敗") }
        return CIImage(cgImage: cgImage)
    }

    private func readMetadata(_ raw: UnsafeMutablePointer<libraw_data_t>) -> RawMetadata {
        let d = raw.pointee
        var meta = RawMetadata()
        meta.make = cString(d.idata.make)
        meta.model = cString(d.idata.model)
        meta.lens = cString(d.lens.Lens)
        meta.iso = Double(d.other.iso_speed)
        meta.shutter = Double(d.other.shutter)
        meta.aperture = Double(d.other.aperture)
        meta.focalLength = Double(d.other.focal_len)
        if d.other.timestamp > 0 {
            meta.captureDate = Date(timeIntervalSince1970: TimeInterval(d.other.timestamp))
        }
        let flipped = d.sizes.flip == 5 || d.sizes.flip == 6
        meta.width = Int(flipped ? d.sizes.height : d.sizes.width)
        meta.height = Int(flipped ? d.sizes.width : d.sizes.height)

        if meta.make.uppercased().hasPrefix("NIKON") {
            let pc = cString(d.makernotes.nikon.PictureControlName)
            meta.pictureControl = pc.isEmpty ? nil : pc
            meta.activeDLighting = Self.adlName(d.makernotes.nikon.ActiveDLighting)
        }
        return meta
    }

    private static func adlName(_ v: UInt16) -> String {
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

    /// C の固定長 char 配列(Swift ではタプル)を String に
    private func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
        }
    }
}
