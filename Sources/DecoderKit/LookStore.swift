import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 見本に合わせて作った色味(3D LUT)と、その見本の縮小コピーをライブラリに置く。
///
/// 現像設定には ID だけを持たせる(LUT は 33³ で大きいので設定の JSON に入れない)。
/// `<directory>/<id>.lut`  RGBA の Float32(赤が最も速く変わる順)
/// `<directory>/<id>.jpg`  見本の縮小コピー(元の画像が消えても合わせ直せるように)
/// `<directory>/<id>.json` 見本のファイル名
public enum LookStore {
    nonisolated(unsafe) public static var directory: URL?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cubes: [String: (size: Int, data: Data)] = [:]
    nonisolated(unsafe) private static var references: [String: CGImage] = [:]

    private struct Meta: Codable {
        var name: String
    }

    /// LUT と見本を保存して ID を返す
    public static func save(_ lut: LookLUT, reference: CGImage, name: String) throws -> String {
        guard let dir = directory else { throw DecoderError.failed("色味の保存先がありません") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let data = lut.rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        try data.write(to: dir.appendingPathComponent("\(id).lut"), options: .atomic)
        try JSONEncoder().encode(Meta(name: name)).write(to: dir.appendingPathComponent("\(id).json"), options: .atomic)
        if let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent("\(id).jpg") as CFURL,
                                                      UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, reference,
                                       [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            CGImageDestinationFinalize(dest)
        }
        lock.lock()
        cubes[id] = (lut.size, data)
        references[id] = reference
        lock.unlock()
        return id
    }

    /// Core Image の CIColorCubeWithColorSpace に渡す形(大きさとデータ)
    public static func cube(_ id: String) -> (size: Int, data: Data)? {
        lock.lock()
        if let c = cubes[id] {
            lock.unlock()
            return c
        }
        lock.unlock()
        guard let dir = directory,
              let data = try? Data(contentsOf: dir.appendingPathComponent("\(id).lut")) else { return nil }
        let n = Int(cbrt(Double(data.count / 16)).rounded())
        guard n >= 2, n * n * n * 16 == data.count else { return nil }
        lock.lock()
        cubes[id] = (n, data)
        lock.unlock()
        return (n, data)
    }

    /// 見本の縮小コピー
    public static func reference(_ id: String) -> CGImage? {
        lock.lock()
        if let r = references[id] {
            lock.unlock()
            return r
        }
        lock.unlock()
        guard let dir = directory,
              let src = CGImageSourceCreateWithURL(dir.appendingPathComponent("\(id).jpg") as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        lock.lock()
        references[id] = image
        lock.unlock()
        return image
    }

    /// 見本のファイル名
    public static func name(_ id: String) -> String? {
        guard let dir = directory,
              let data = try? Data(contentsOf: dir.appendingPathComponent("\(id).json")) else { return nil }
        return (try? JSONDecoder().decode(Meta.self, from: data))?.name
    }

    /// 現像の最後に色味をかける。強さ 0〜100(%)
    static func apply(_ image: CIImage, id: String, strength: Double) -> CIImage {
        guard strength > 0, let c = cube(id) else { return image }
        let looked = image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": c.size,
            "inputCubeData": c.data,
            "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!,
        ])
        guard strength < 100 else { return looked }
        return looked.applyingFilter("CIMix", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputAmountKey: strength / 100,
        ])
    }
}

/// 見本の写真。色は sRGB に変換してから数える
public struct ReferenceImage: @unchecked Sendable {
    public let name: String
    /// 長辺 640 の縮小(sRGB)
    public let thumbnail: CGImage
    public let samples: [SIMD3<Float>]

    public init(url: URL, maximumPixelSize: Int = 640) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
              ] as CFDictionary)
        else { throw DecoderError.failed("画像を読み込めません: \(url.lastPathComponent)") }
        try self.init(image: decoded, name: url.lastPathComponent)
    }

    public init(image: CGImage, name: String) throws {
        guard let (srgb, samples) = LookMatcher.srgbSamples(of: image) else {
            throw DecoderError.failed("画像を読み込めません: \(name)")
        }
        self.name = name
        self.thumbnail = srgb
        self.samples = samples
    }
}

extension LookMatcher {
    /// 画像を sRGB に変換し(ICC プロファイルは CoreGraphics が処理)、最大 6 万点の色を取り出す
    public static func srgbSamples(of image: CGImage, maximumCount: Int = 60000) -> (CGImage, [SIMD3<Float>])? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let converted = bytes.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return ctx.makeImage()
        }
        guard let converted else { return nil }
        let samples = stride(from: 0, to: width * height, by: max(1, width * height / maximumCount)).map { pixel in
            let o = pixel * 4
            return SIMD3(Float(bytes[o]), Float(bytes[o + 1]), Float(bytes[o + 2])) / 255
        }
        return (converted, samples)
    }
}
