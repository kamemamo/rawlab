import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 現像設定。どのデコーダーの出力にも同じものを当てる。
public struct DevelopSettings: Hashable, Sendable, Codable {
    public var exposure: Double = 0       // EV
    public var temperature: Double = 0    // 色温度の補正(K)。+ で暖かく
    public var tint: Double = 0           // + でマゼンタ寄り
    public var contrast: Double = 0       // -1...1
    public var highlights: Double = 0     // 0...1 ハイライト復元
    public var shadows: Double = 0        // -1...1
    public var vibrance: Double = 0       // -1...1
    public var saturation: Double = 0     // -1...1
    public var noiseReduction: Double = 0 // 0...1 パイプライン側 NR
    public var sharpness: Double = 0      // 0...1

    public init() {}
}

public enum DevelopPipeline {
    /// 共通の CIContext(作業空間はリニア、16bit float)
    public static let context = CIContext(options: [
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false,
    ])

    public static func apply(_ s: DevelopSettings, to input: CIImage) -> CIImage {
        var img = input

        if s.exposure != 0 {
            img = img.applyingFilter("CIExposureAdjust", parameters: ["inputEV": s.exposure])
        }
        if s.temperature != 0 || s.tint != 0 {
            // neutral → targetNeutral の変換。target を下げると暖色寄りになる
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 - s.temperature, y: -s.tint),
            ])
        }
        if s.highlights != 0 || s.shadows != 0 {
            img = img.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 - s.highlights,
                "inputShadowAmount": s.shadows,
            ])
        }
        if s.noiseReduction > 0 {
            img = img.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": s.noiseReduction * 0.06,
                "inputSharpness": 0.4,
            ])
        }

        // ベースのトーンカーブ(sRGB ガンマ空間でゆるい S 字)。contrast で強さを変える
        let k = 1 + s.contrast
        img = img
            .applyingFilter("CILinearToSRGBToneCurve")
            .applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0),
                "inputPoint1": CIVector(x: 0.25, y: 0.25 - 0.06 * k),
                "inputPoint2": CIVector(x: 0.5, y: 0.5),
                "inputPoint3": CIVector(x: 0.75, y: 0.75 + 0.05 * k),
                "inputPoint4": CIVector(x: 1, y: 1),
            ])
            .applyingFilter("CISRGBToneCurveToLinear")

        if s.vibrance != 0 {
            img = img.applyingFilter("CIVibrance", parameters: ["inputAmount": s.vibrance])
        }
        if s.saturation != 0 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1 + s.saturation,
            ])
        }
        if s.sharpness > 0 {
            img = img.applyingFilter("CISharpenLuminance", parameters: [
                "inputSharpness": s.sharpness * 1.5,
                "inputRadius": 1.5,
            ])
        }
        return img
    }

    /// 長辺 maxPixel に縮小(プレビュー用)
    public static func scaled(_ image: CIImage, maxPixel: CGFloat) -> CIImage {
        let longest = max(image.extent.width, image.extent.height)
        guard longest > maxPixel else { return image }
        let scale = maxPixel / longest
        return image.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0,
        ])
    }

    /// RAW デコード結果を縮小して float16 のビットマップに確定させる。
    /// CIImage は遅延評価なので、これをしないとスライダーを動かすたびに RAW を読み直してしまう。
    public static func materialize(_ image: CIImage, maxPixel: CGFloat) -> CIImage? {
        let scaledImage = scaled(image, maxPixel: maxPixel)
        let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
        guard let cg = context.createCGImage(scaledImage, from: scaledImage.extent,
                                             format: .RGBAh, colorSpace: space)
        else { return nil }
        return CIImage(cgImage: cg)
    }

    public static func renderCGImage(_ image: CIImage) -> CGImage? {
        context.createCGImage(image, from: image.extent,
                              format: .RGBA8,
                              colorSpace: CGColorSpace(name: CGColorSpace.displayP3))
    }
}

// MARK: - 書き出し

public enum ExportFormat: String, CaseIterable, Sendable, Codable {
    case jpeg, tiff, heic

    public var fileExtension: String { rawValue == "jpeg" ? "jpg" : rawValue }
}

public enum Exporter {
    public static func export(
        _ image: CIImage, to url: URL, format: ExportFormat,
        quality: Double = 0.92, colorSpaceName: CFString = CGColorSpace.displayP3
    ) throws {
        let ctx = DevelopPipeline.context
        let space = CGColorSpace(name: colorSpaceName)!
        let options = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        switch format {
        case .jpeg:
            try ctx.writeJPEGRepresentation(of: image, to: url, colorSpace: space, options: options)
        case .tiff:
            try ctx.writeTIFFRepresentation(of: image, to: url, format: .RGBA16, colorSpace: space)
        case .heic:
            try ctx.writeHEIFRepresentation(of: image, to: url, format: .RGBA8,
                                            colorSpace: space, options: options)
        }
    }
}

// MARK: - サムネイル(RAW 内蔵 JPEG を使うので速い。デコーダー共通)

public enum RawThumbnail {
    public static func make(_ url: URL, maxPixel: Int = 400) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
    }
}

// MARK: - 将来項目を足しても古い保存データを読めるよう、欠けているキーは既定値にする

extension DevelopSettings {
    private enum Keys: String, CodingKey {
        case exposure, temperature, tint, contrast, highlights, shadows, vibrance, saturation, noiseReduction, sharpness
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init()
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        noiseReduction = try c.decodeIfPresent(Double.self, forKey: .noiseReduction) ?? 0
        sharpness = try c.decodeIfPresent(Double.self, forKey: .sharpness) ?? 0
    }
}

extension DecodeOptions {
    private enum Keys: String, CodingKey {
        case demosaic, applyAsShotWB, halfSize, noiseReduction
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init()
        demosaic = try c.decodeIfPresent(DemosaicMethod.self, forKey: .demosaic) ?? .auto
        applyAsShotWB = try c.decodeIfPresent(Bool.self, forKey: .applyAsShotWB) ?? true
        halfSize = try c.decodeIfPresent(Bool.self, forKey: .halfSize) ?? false
        noiseReduction = try c.decodeIfPresent(Double.self, forKey: .noiseReduction) ?? 0
    }
}
