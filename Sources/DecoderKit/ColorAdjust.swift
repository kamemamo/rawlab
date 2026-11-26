import CoreImage
import Foundation

/// 色の系統(HSL 調整の対象)。中心の色相は OKLCH の角度(度)
public enum ColorRange: Int, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case red, orange, yellow, green, aqua, blue, purple, magenta

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .red: "赤"
        case .orange: "オレンジ"
        case .yellow: "黄"
        case .green: "緑"
        case .aqua: "水色"
        case .blue: "青"
        case .purple: "紫"
        case .magenta: "マゼンタ"
        }
    }

    /// OKLCH での中心の色相(度)
    public var centerHue: Double {
        switch self {
        case .red: 25
        case .orange: 55
        case .yellow: 100
        case .green: 140
        case .aqua: 195
        case .blue: 255
        case .purple: 295
        case .magenta: 335
        }
    }

    /// 画面に出す見本の色(sRGB)
    public var swatch: (r: Double, g: Double, b: Double) {
        let (r, g, b) = OKLab.toSRGB(L: 0.68, C: 0.16, hueDegrees: centerHue)
        return (r, g, b)
    }

    /// 色相に一番近い系統
    public static func nearest(hueDegrees h: Double) -> ColorRange {
        allCases.min { OKLab.hueDistance($0.centerHue, h) < OKLab.hueDistance($1.centerHue, h) }!
    }
}

/// 1 系統分の調整
public struct HSLValue: Codable, Hashable, Sendable {
    /// 色相(度、±30)
    public var hue: Double = 0
    /// 彩度(-1 で無彩色、+1 で 2 倍)
    public var saturation: Double = 0
    /// 明度(±1)
    public var luminance: Double = 0

    public init() {}
    public var isZero: Bool { hue == 0 && saturation == 0 && luminance == 0 }
}

/// 8 系統分の調整。`\DevelopSettings.colorAdjustments[.blue].saturation` のように使う
public struct ColorAdjustments: Codable, Hashable, Sendable {
    public var values: [HSLValue] = Array(repeating: HSLValue(), count: ColorRange.allCases.count)

    public init() {}

    public subscript(range: ColorRange) -> HSLValue {
        get { values[range.rawValue] }
        set { values[range.rawValue] = newValue }
    }

    public var isZero: Bool { values.allSatisfy(\.isZero) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let decoded = (try? c.decode([HSLValue].self)) ?? []
        values = (0..<ColorRange.allCases.count).map { $0 < decoded.count ? decoded[$0] : HSLValue() }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(values)
    }

    /// 色相 h(度)での調整量。隣り合う系統の間はなめらかに混ぜる
    func adjustment(atHue h: Double) -> (hue: Double, saturation: Double, luminance: Double) {
        let ranges = ColorRange.allCases
        var result = (hue: 0.0, saturation: 0.0, luminance: 0.0)
        for (i, r) in ranges.enumerated() {
            let next = ranges[(i + 1) % ranges.count]
            var span = next.centerHue - r.centerHue
            if span <= 0 { span += 360 }
            var d = h - r.centerHue
            if d < 0 { d += 360 }
            guard d < span else { continue }
            // r と next の間: 滑らかに重みを移す
            let t = d / span
            let w = t * t * (3 - 2 * t)
            let a = self[r], b = self[next]
            result.hue = a.hue * (1 - w) + b.hue * w
            result.saturation = a.saturation * (1 - w) + b.saturation * w
            result.luminance = a.luminance * (1 - w) + b.luminance * w
            break
        }
        return result
    }
}

// MARK: - OKLab / OKLCH(人の見え方に近い色空間)

public enum OKLab {
    static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func linearToSRGB(_ c: Double) -> Double {
        c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    /// リニア sRGB → OKLab
    static func fromLinear(_ r: Double, _ g: Double, _ b: Double) -> (L: Double, a: Double, b: Double) {
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// OKLab → リニア sRGB
    static func toLinear(_ L: Double, _ a: Double, _ b: Double) -> (Double, Double, Double) {
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    /// sRGB(ガンマあり 0〜1)→ (L, C, 色相の度)
    public static func lch(fromSRGB r: Double, _ g: Double, _ b: Double) -> (L: Double, C: Double, h: Double) {
        let lab = fromLinear(srgbToLinear(r), srgbToLinear(g), srgbToLinear(b))
        var h = atan2(lab.b, lab.a) * 180 / .pi
        if h < 0 { h += 360 }
        return (lab.L, hypot(lab.a, lab.b), h)
    }

    public static func toSRGB(L: Double, C: Double, hueDegrees h: Double) -> (Double, Double, Double) {
        let rad = h * .pi / 180
        let (r, g, b) = toLinear(L, C * cos(rad), C * sin(rad))
        return (linearToSRGB(min(max(r, 0), 1)), linearToSRGB(min(max(g, 0), 1)), linearToSRGB(min(max(b, 0), 1)))
    }

    static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }
}

// MARK: - 3 次元の色対応表(LUT)

enum ColorCube {
    static let dimension = 32
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [ColorAdjustments: Data] = [:]

    /// 調整ごとに 1 回だけ作って使い回す(サムネイルを何枚描いても速い)
    static func data(for adj: ColorAdjustments) -> Data {
        lock.lock()
        if let d = cache[adj] {
            lock.unlock()
            return d
        }
        lock.unlock()
        let d = build(adj)
        lock.lock()
        if cache.count > 64 { cache.removeAll() }
        cache[adj] = d
        lock.unlock()
        return d
    }

    private static func build(_ adj: ColorAdjustments) -> Data {
        let n = dimension
        var cube = [Float](repeating: 1, count: n * n * n * 4)
        cube.withUnsafeMutableBufferPointer { p in
        DispatchQueue.concurrentPerform(iterations: n) { bi in
            for gi in 0..<n {
                for ri in 0..<n {
                    let r = Double(ri) / Double(n - 1), g = Double(gi) / Double(n - 1), b = Double(bi) / Double(n - 1)
                    let (L, C, h) = OKLab.lch(fromSRGB: r, g, b)
                    // 色の薄い所(白・灰色・黒)にはほとんど効かせない
                    let x = min(max((C - 0.015) / 0.06, 0), 1)
                    let protect = x * x * (3 - 2 * x)
                    var out = (r, g, b)
                    if protect > 0 {
                        let a = adj.adjustment(atHue: h)
                        let newH = h + a.hue * protect
                        var newC = C * max(1 + a.saturation * protect, 0)
                        let newL = min(max(L + a.luminance * 0.15 * protect * (1 - abs(L - 0.5)), 0), 1)
                        // 表せない色になったら彩度を少しずつ下げる
                        var rgb = OKLab.toLinear(newL, newC * cos(newH * .pi / 180), newC * sin(newH * .pi / 180))
                        var tries = 0
                        while tries < 12, rgb.0 < -0.001 || rgb.1 < -0.001 || rgb.2 < -0.001
                                || rgb.0 > 1.001 || rgb.1 > 1.001 || rgb.2 > 1.001 {
                            newC *= 0.9
                            rgb = OKLab.toLinear(newL, newC * cos(newH * .pi / 180), newC * sin(newH * .pi / 180))
                            tries += 1
                        }
                        out = (OKLab.linearToSRGB(min(max(rgb.0, 0), 1)),
                               OKLab.linearToSRGB(min(max(rgb.1, 0), 1)),
                               OKLab.linearToSRGB(min(max(rgb.2, 0), 1)))
                    }
                    let i = ((bi * n + gi) * n + ri) * 4
                    p[i] = Float(out.0); p[i + 1] = Float(out.1); p[i + 2] = Float(out.2); p[i + 3] = 1
                }
            }
        }
        }
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func apply(_ image: CIImage, _ adj: ColorAdjustments) -> CIImage {
        image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": dimension,
            "inputCubeData": data(for: adj),
            "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!,
        ])
    }
}
