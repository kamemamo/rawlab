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

    // レベル補正(sRGB ガンマ空間で 0...1)
    public var levelsBlack: Double = 0
    public var levelsGamma: Double = 1    // 1 で変化なし。大きいほど中間が明るい
    public var levelsWhite: Double = 1
    /// トーンカーブの点(sRGB ガンマ空間、0...1)。空なら直線
    public var curve: [CurvePoint] = []
    /// ハイライト圧縮 0...1。1 を超える明るさを肩の丸いカーブで 1 以内に収める(白飛びの復元と組み合わせる)
    public var highlightRolloff: Double = 0
    /// 色ごとの露出(EV)。カメラの色を変換した後のリニアな R・G・B にそれぞれ 2^EV を掛ける
    public var exposureR: Double = 0
    public var exposureG: Double = 0
    public var exposureB: Double = 0
    /// 色ごとの調整(8 系統 × 色相・彩度・明度)
    public var colorAdjustments = ColorAdjustments()

    public init() {}

    public var hasToneAdjustments: Bool {
        levelsBlack != 0 || levelsGamma != 1 || levelsWhite != 1 || !curve.isEmpty
    }

    /// レベル補正のあとにトーンカーブをかける 1 次元の対応表(count 段階、0...1)
    public func toneLUT(count: Int = 256) -> [Float] {
        let points = ToneCurve.normalized(curve)
        let range = max(levelsWhite - levelsBlack, 0.001)
        return (0..<count).map { i in
            let x = Double(i) / Double(count - 1)
            let t = min(max((x - levelsBlack) / range, 0), 1)
            let leveled = pow(t, 1 / max(levelsGamma, 0.01))
            return Float(min(max(ToneCurve.evaluate(points, at: leveled), 0), 1))
        }
    }
}

/// トーンカーブの点
public struct CurvePoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// 点を滑らかにつなぐ(行き過ぎない単調 3 次補間 / Fritsch–Carlson)
public enum ToneCurve {
    /// 両端 (0,0)(1,1) を補い、x 順に並べる
    public static func normalized(_ points: [CurvePoint]) -> [CurvePoint] {
        var p = points.sorted { $0.x < $1.x }
        if p.first.map({ $0.x > 0.0001 }) ?? true { p.insert(CurvePoint(x: 0, y: 0), at: 0) }
        if p.last.map({ $0.x < 0.9999 }) ?? true { p.append(CurvePoint(x: 1, y: 1)) }
        return p
    }

    public static func evaluate(_ p: [CurvePoint], at x: Double) -> Double {
        guard p.count >= 2 else { return x }
        if x <= p[0].x { return p[0].y }
        if x >= p[p.count - 1].x { return p[p.count - 1].y }
        let n = p.count
        var d = [Double](repeating: 0, count: n - 1)  // 区間の傾き
        for i in 0..<(n - 1) { d[i] = (p[i + 1].y - p[i].y) / max(p[i + 1].x - p[i].x, 1e-6) }
        var m = [Double](repeating: 0, count: n)     // 各点での傾き
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 }
        for i in 0..<(n - 1) where d[i] == 0 {
            m[i] = 0
            m[i + 1] = 0
        }
        for i in 0..<(n - 1) where d[i] != 0 {
            let a = m[i] / d[i], b = m[i + 1] / d[i]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / sqrt(s)
                m[i] = t * a * d[i]
                m[i + 1] = t * b * d[i]
            }
        }
        var k = 0
        while k < n - 2 && x > p[k + 1].x { k += 1 }
        let h = p[k + 1].x - p[k].x
        let t = (x - p[k].x) / h
        let t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * p[k].y + (t3 - 2 * t2 + t) * h * m[k]
            + (-2 * t3 + 3 * t2) * p[k + 1].y + (t3 - t2) * h * m[k + 1]
    }
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
            img = whiteBalance(img, temperature: s.temperature, tint: s.tint)
        }
        if s.exposureR != 0 || s.exposureG != 0 || s.exposureB != 0 {
            img = img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: pow(2, s.exposureR), y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: pow(2, s.exposureG), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: pow(2, s.exposureB), w: 0),
            ])
        }
        if s.highlightRolloff > 0 {
            img = rolloff(img, amount: s.highlightRolloff)
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

        // レベル補正 + トーンカーブ(sRGB ガンマ空間で 1 次元の対応表)
        if s.hasToneAdjustments {
            let lut = s.toneLUT().flatMap { [$0, $0, $0] }
            img = img.applyingFilter("CIColorCurves", parameters: [
                "inputCurvesData": lut.withUnsafeBufferPointer { Data(buffer: $0) },
                "inputCurvesDomain": CIVector(x: 0, y: 1),
                "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!,
            ])
        }

        // 色ごとの調整(OKLCH で計算した 3 次元の対応表)
        if !s.colorAdjustments.isZero {
            img = ColorCube.apply(img, s.colorAdjustments)
        }
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

    /// ハイライト圧縮(リニアのまま)。
    /// 膝 k より上の明るさを、白点 W までが 1 に収まるよう対数の肩で丸める。膝では傾きが 1 なので段差が出ない。
    /// 強さ 0〜1 で k = 1 → 0.5、W = 1 → 5(元の白の 5 倍の明るさまで階調を残す)
    static func rolloff(_ image: CIImage, amount: Double) -> CIImage {
        let a = min(max(amount, 0), 1)
        let knee = 1 - 0.5 * a
        let whitePoint = 1 + 4 * a
        // 膝で傾き 1 になる係数 c を二分法で求める: (1-k)·c / log(1 + c·(W-k)) = 1
        var lo = 1e-6, hi = 1e4
        for _ in 0..<80 {
            let c = (lo + hi) / 2
            let slope = (1 - knee) * c / log(1 + c * (whitePoint - knee))
            if slope < 1 { lo = c } else { hi = c }
        }
        let c = (lo + hi) / 2
        let norm = log(1 + c * (whitePoint - knee))
        let maxIn = 8.0
        let count = 2048
        let lut: [Float] = (0..<count).flatMap { i -> [Float] in
            let x = Double(i) / Double(count - 1) * maxIn
            let y = x <= knee ? x : min(knee + (1 - knee) * log(1 + c * (x - knee)) / norm, 1)
            return [Float(y), Float(y), Float(y)]
        }
        return image.applyingFilter("CIColorCurves", parameters: [
            "inputCurvesData": lut.withUnsafeBufferPointer { Data(buffer: $0) },
            "inputCurvesDomain": CIVector(x: 0, y: CGFloat(maxIn)),
            "inputColorSpace": CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        ])
    }

    /// 色温度・色かぶりの補正(neutral → targetNeutral の変換。target を下げると暖色寄りになる)。
    /// スポイトもこれを使って同じ計算で中立点を探す
    public static func whiteBalance(_ image: CIImage, temperature: Double, tint: Double) -> CIImage {
        image.applyingFilter("CITemperatureAndTint", parameters: [
            "inputNeutral": CIVector(x: 6500, y: 0),
            "inputTargetNeutral": CIVector(x: 6500 - temperature, y: -tint),
        ])
    }

    /// スポイト: 指定した点(画像に対する割合、左上原点)が無彩色になる色温度・色かぶりを探す。
    /// 7×7 ピクセルの平均を取り、R/G と B/G が 1 に近づくよう座標ごとに黄金分割探索する
    public static func solveWhiteBalance(
        _ image: CIImage, at point: CGPoint,
        temperatureRange: ClosedRange<Double>, tintRange: ClosedRange<Double>
    ) -> (temperature: Double, tint: Double)? {
        guard let sample = samplePoint(image, at: point) else { return nil }
        let (r0, g0, b0) = rgb(sample)
        // 真っ黒・白飛びの点では決められない
        guard min(r0, g0, b0) > 0.002, max(r0, g0, b0) < 0.98 else { return nil }

        func cost(_ t: Double, _ ti: Double) -> Double {
            let (r, g, b) = rgb(whiteBalance(sample, temperature: t, tint: ti))
            guard r > 0, g > 0, b > 0 else { return .infinity }
            let a = log(Double(r / g)), c = log(Double(b / g))
            return a * a + c * c
        }
        func golden(_ range: ClosedRange<Double>, _ f: (Double) -> Double) -> Double {
            let k = (sqrt(5.0) - 1) / 2
            var lo = range.lowerBound, hi = range.upperBound
            var m1 = hi - k * (hi - lo), m2 = lo + k * (hi - lo)
            var f1 = f(m1), f2 = f(m2)
            for _ in 0..<24 {
                if f1 < f2 {
                    hi = m2; m2 = m1; f2 = f1
                    m1 = hi - k * (hi - lo); f1 = f(m1)
                } else {
                    lo = m1; m1 = m2; f1 = f2
                    m2 = lo + k * (hi - lo); f2 = f(m2)
                }
            }
            return (lo + hi) / 2
        }
        var t = 0.0, ti = 0.0
        for _ in 0..<4 {
            t = golden(temperatureRange) { cost($0, ti) }
            ti = golden(tintRange) { cost(t, $0) }
        }
        return (t, ti)
    }

    /// 指定した点(割合、左上原点)の 7×7 ピクセル平均を 1 ピクセルの画像で返す
    public static func samplePoint(_ image: CIImage, at point: CGPoint) -> CIImage? {
        let e = image.extent
        let x = e.minX + point.x * e.width
        let y = e.maxY - point.y * e.height  // Core Image は左下原点
        let rect = CGRect(x: x - 3, y: y - 3, width: 7, height: 7).intersection(e)
        guard !rect.isEmpty else { return nil }
        return image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
    }

    /// 1 ピクセル目の色(作業空間 = リニア)
    public static func rgb(_ img: CIImage) -> (Float, Float, Float) {
        var px = [Float](repeating: 0, count: 4)
        context.render(img, toBitmap: &px, rowBytes: 16,
                       bounds: CGRect(origin: img.extent.origin, size: CGSize(width: 1, height: 1)),
                       format: .RGBAf, colorSpace: nil)
        return (px[0], px[1], px[2])
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
        case levelsBlack, levelsGamma, levelsWhite, curve, highlightRolloff
        case exposureR, exposureG, exposureB, colorAdjustments
    }

    /// 後から足した項目は既定値なら書かない(既存バージョンの内容ハッシュが変わって
    /// 「要再書き出し」にならないように)
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(exposure, forKey: .exposure)
        try c.encode(temperature, forKey: .temperature)
        try c.encode(tint, forKey: .tint)
        try c.encode(contrast, forKey: .contrast)
        try c.encode(highlights, forKey: .highlights)
        try c.encode(shadows, forKey: .shadows)
        try c.encode(vibrance, forKey: .vibrance)
        try c.encode(saturation, forKey: .saturation)
        try c.encode(noiseReduction, forKey: .noiseReduction)
        try c.encode(sharpness, forKey: .sharpness)
        if levelsBlack != 0 { try c.encode(levelsBlack, forKey: .levelsBlack) }
        if levelsGamma != 1 { try c.encode(levelsGamma, forKey: .levelsGamma) }
        if levelsWhite != 1 { try c.encode(levelsWhite, forKey: .levelsWhite) }
        if !curve.isEmpty { try c.encode(curve, forKey: .curve) }
        if highlightRolloff != 0 { try c.encode(highlightRolloff, forKey: .highlightRolloff) }
        if exposureR != 0 { try c.encode(exposureR, forKey: .exposureR) }
        if exposureG != 0 { try c.encode(exposureG, forKey: .exposureG) }
        if exposureB != 0 { try c.encode(exposureB, forKey: .exposureB) }
        if !colorAdjustments.isZero { try c.encode(colorAdjustments, forKey: .colorAdjustments) }
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
        levelsBlack = try c.decodeIfPresent(Double.self, forKey: .levelsBlack) ?? 0
        levelsGamma = try c.decodeIfPresent(Double.self, forKey: .levelsGamma) ?? 1
        levelsWhite = try c.decodeIfPresent(Double.self, forKey: .levelsWhite) ?? 1
        curve = try c.decodeIfPresent([CurvePoint].self, forKey: .curve) ?? []
        highlightRolloff = try c.decodeIfPresent(Double.self, forKey: .highlightRolloff) ?? 0
        exposureR = try c.decodeIfPresent(Double.self, forKey: .exposureR) ?? 0
        exposureG = try c.decodeIfPresent(Double.self, forKey: .exposureG) ?? 0
        exposureB = try c.decodeIfPresent(Double.self, forKey: .exposureB) ?? 0
        colorAdjustments = try c.decodeIfPresent(ColorAdjustments.self, forKey: .colorAdjustments) ?? ColorAdjustments()
    }
}

extension DecodeOptions {
    private enum Keys: String, CodingKey {
        case demosaic, applyAsShotWB, halfSize, noiseReduction, highlight
    }

    /// 後から足した項目は既定値なら書かない(既存バージョンの内容ハッシュを変えない)
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(demosaic, forKey: .demosaic)
        try c.encode(applyAsShotWB, forKey: .applyAsShotWB)
        try c.encode(halfSize, forKey: .halfSize)
        try c.encode(noiseReduction, forKey: .noiseReduction)
        if highlight != .clip { try c.encode(highlight, forKey: .highlight) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init()
        demosaic = try c.decodeIfPresent(DemosaicMethod.self, forKey: .demosaic) ?? .auto
        applyAsShotWB = try c.decodeIfPresent(Bool.self, forKey: .applyAsShotWB) ?? true
        halfSize = try c.decodeIfPresent(Bool.self, forKey: .halfSize) ?? false
        noiseReduction = try c.decodeIfPresent(Double.self, forKey: .noiseReduction) ?? 0
        highlight = try c.decodeIfPresent(HighlightMode.self, forKey: .highlight) ?? .clip
    }
}
