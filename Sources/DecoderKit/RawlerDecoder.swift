import CoreImage
import CRawler
import Foundation
import ImageIO

/// Rust 製 rawler(dnglab の中核)を C ABI 経由で呼ぶデコーダー。
/// rawler のデモザイクは PPG 固定、ノイズリダクションなし。
/// 出力はリニア sRGB(D65)の RGBA f32 で、Rust 側のバッファをコピーせずに CIImage にする。
public struct RawlerDecoder: RawDecoder {
    public let id = "rawler"
    public let displayName = "rawler \(String(cString: rl_version()))"

    public init() {}

    /// JPEG XL の DNG は読めない(LibRaw は Adobe DNG SDK なし、rawler 0.8 は未対応)
    public func unsupportedReason(_ url: URL) -> String? {
        DNGCompression.isJPEGXL(url) ? DNGCompression.jpegXLReason : nil
    }

    public func decode(_ url: URL, options: DecodeOptions) throws -> DecodedImage {
        if let reason = unsupportedReason(url) { throw DecoderError.failed("\(displayName): \(reason)") }
        let start = Date()
        var out = RlImage()
        var err = [CChar](repeating: 0, count: 512)
        let code = url.withUnsafeFileSystemRepresentation { path in
            rl_decode(path, options.applyAsShotWB, &out, &err, err.count)
        }
        guard code == 0, let pixels = out.data else {
            throw DecoderError.failed("rawler: \(String(cString: err))")
        }

        let width = Int(out.width)
        let height = Int(out.height)
        let len = out.len
        // Rust の Vec をそのまま使い、CIImage が不要になったら Rust 側で解放する
        let data = Data(
            bytesNoCopy: pixels, count: len * MemoryLayout<Float>.size,
            deallocator: .custom { ptr, _ in
                rl_image_free(ptr.assumingMemoryBound(to: Float.self), len)
            })
        var image = CIImage(
            bitmapData: data,
            bytesPerRow: width * 4 * MemoryLayout<Float>.size,
            size: CGSize(width: width, height: height),
            format: .RGBAf,
            colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB))

        if let orientation = CGImagePropertyOrientation(rawValue: UInt32(out.orientation)),
           orientation != .up {
            image = image.oriented(orientation)
        }
        // rawler には半分サイズのデコードがないので縮小で代用
        if options.halfSize {
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: 0.5, kCIInputAspectRatioKey: 1.0,
            ])
        }

        return DecodedImage(
            image: image,
            metadata: (try? metadata(url)) ?? RawMetadata(),
            decoderID: id,
            options: options,
            decodeTime: Date().timeIntervalSince(start)
        )
    }

    public func metadata(_ url: URL) throws -> RawMetadata {
        var m = RlMetadata()
        var err = [CChar](repeating: 0, count: 512)
        let code = url.withUnsafeFileSystemRepresentation { path in
            rl_metadata(path, &m, &err, err.count)
        }
        guard code == 0 else { throw DecoderError.failed("rawler: \(String(cString: err))") }

        var meta = RawMetadata()
        meta.make = cString(m.make)
        meta.model = cString(m.model)
        meta.lens = cString(m.lens)
        meta.iso = m.iso
        meta.shutter = m.shutter
        meta.aperture = m.aperture
        meta.focalLength = m.focal_length
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        meta.captureDate = f.date(from: cString(m.date))
        return meta
    }

    private func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
