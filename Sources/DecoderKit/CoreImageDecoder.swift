import CoreImage
import Foundation
import ImageIO

/// macOS 標準の RAW デコーダー (CIRAWFilter)。
/// トーンカーブ・シャープ・ローカルトーンマップを切って、リニアに近い出力にする。
public struct CoreImageDecoder: RawDecoder {
    public let id = "coreimage"
    public let displayName = "Core Image"

    public init() {}

    public func decode(_ url: URL, options: DecodeOptions) throws -> DecodedImage {
        let start = Date()
        guard let filter = CIRAWFilter(imageURL: url) else {
            throw DecoderError.unsupported(url)
        }
        filter.boostAmount = 0          // Apple のトーンカーブを適用しない
        filter.boostShadowAmount = 0
        filter.localToneMapAmount = 0
        filter.sharpnessAmount = 0
        filter.contrastAmount = 0
        filter.detailAmount = 0
        filter.luminanceNoiseReductionAmount = Float(options.noiseReduction)
        filter.colorNoiseReductionAmount = Float(options.noiseReduction)
        if options.halfSize {
            filter.scaleFactor = 0.5
        }
        if !options.applyAsShotWB {
            filter.neutralTemperature = 5500
            filter.neutralTint = 0
        }
        guard let image = filter.outputImage else {
            throw DecoderError.failed("Core Image でデコードできませんでした")
        }
        return DecodedImage(
            image: image,
            metadata: try metadata(url),
            decoderID: id,
            options: options,
            decodeTime: Date().timeIntervalSince(start)
        )
    }

    public func metadata(_ url: URL) throws -> RawMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { throw DecoderError.unsupported(url) }

        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]

        var meta = RawMetadata()
        meta.make = tiff[kCGImagePropertyTIFFMake] as? String ?? ""
        meta.model = tiff[kCGImagePropertyTIFFModel] as? String ?? ""
        meta.lens = exif[kCGImagePropertyExifLensModel] as? String
            ?? aux[kCGImagePropertyExifAuxLensModel] as? String ?? ""
        meta.iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Double])?.first ?? 0
        meta.shutter = exif[kCGImagePropertyExifExposureTime] as? Double ?? 0
        meta.aperture = exif[kCGImagePropertyExifFNumber] as? Double ?? 0
        meta.focalLength = exif[kCGImagePropertyExifFocalLength] as? Double ?? 0
        meta.width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        meta.height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        if let date = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let f = DateFormatter()
            f.dateFormat = "yyyy:MM:dd HH:mm:ss"
            meta.captureDate = f.date(from: date)
        }
        return meta
    }
}
