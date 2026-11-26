// ZR Grade(red-zr)の GradeCore/LookMatch.swift から移植。
// 見本の写真の色味に、今の写真を近づける 3D LUT を作る。
import CoreGraphics
import Foundation
import ImageIO
import simd

/// sRGB 表示値を入出力とする 3D LUT。赤が最も速く変わる順で RGBA を並べる。
public struct LookLUT: Sendable {
    public let size: Int
    public let rgba: [Float]

    public init(size: Int, rgba: [Float]) {
        self.size = size
        self.rgba = rgba
    }

    public static func identity(size: Int = 2) -> LookLUT {
        LookMatcher.buildLUT(size: size) { $0 }
    }

    /// CPU での三線形補間。テストと解析に使う。
    public func apply(_ color: SIMD3<Float>) -> SIMD3<Float> {
        let scaled = simd_clamp(color, SIMD3(repeating: 0), SIMD3(repeating: 1)) * Float(size - 1)
        let low = SIMD3<Int>(Int(scaled.x), Int(scaled.y), Int(scaled.z))
        let high = SIMD3<Int>(min(low.x + 1, size - 1), min(low.y + 1, size - 1), min(low.z + 1, size - 1))
        let t = scaled - SIMD3<Float>(Float(low.x), Float(low.y), Float(low.z))

        func node(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> {
            let offset = ((b * size + g) * size + r) * 4
            return SIMD3(rgba[offset], rgba[offset + 1], rgba[offset + 2])
        }

        let c00 = simd_mix(node(low.x, low.y, low.z), node(high.x, low.y, low.z), SIMD3(repeating: t.x))
        let c10 = simd_mix(node(low.x, high.y, low.z), node(high.x, high.y, low.z), SIMD3(repeating: t.x))
        let c01 = simd_mix(node(low.x, low.y, high.z), node(high.x, low.y, high.z), SIMD3(repeating: t.x))
        let c11 = simd_mix(node(low.x, high.y, high.z), node(high.x, high.y, high.z), SIMD3(repeating: t.x))
        let c0 = simd_mix(c00, c10, SIMD3(repeating: t.y))
        let c1 = simd_mix(c01, c11, SIMD3(repeating: t.y))
        return simd_mix(c0, c1, SIMD3(repeating: t.z))
    }
}

public enum LookOklab {
    public static func srgbDecode(_ x: Float) -> Float {
        x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }

    public static func srgbEncode(_ x: Float) -> Float {
        x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055
    }

    /// sRGB 表示値から LookOklab へ。
    public static func fromSRGB(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let r = srgbDecode(c.x), g = srgbDecode(c.y), b = srgbDecode(c.z)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return SIMD3(
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        )
    }

    /// LookOklab からリニア sRGB へ。範囲外の値もそのまま返す。
    public static func toLinearSRGB(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        let l = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z
        let m = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z
        let s = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z
        let l3 = l * l * l, m3 = m * m * m, s3 = s * s * s
        return SIMD3(
            4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
            -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
            -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3
        )
    }

    /// 色域に収まるまで彩度を下げ、sRGB 表示値を返す。
    public static func toSRGBInGamut(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        let lightness = max(0, min(1, lab.x))
        func inGamut(_ c: SIMD3<Float>) -> Bool {
            c.min() >= -0.0005 && c.max() <= 1.0005
        }

        var linear = toLinearSRGB(SIMD3(lightness, lab.y, lab.z))
        if !inGamut(linear) {
            var low: Float = 0
            var high: Float = 1
            for _ in 0..<12 {
                let middle = (low + high) / 2
                let candidate = toLinearSRGB(SIMD3(lightness, lab.y * middle, lab.z * middle))
                if inGamut(candidate) { low = middle } else { high = middle }
            }
            linear = toLinearSRGB(SIMD3(lightness, lab.y * low, lab.z * low))
        }
        let clamped = simd_clamp(linear, SIMD3(repeating: 0), SIMD3(repeating: 1))
        return SIMD3(srgbEncode(clamped.x), srgbEncode(clamped.y), srgbEncode(clamped.z))
    }
}


public enum LookMatcher {
    private static let curveSize = 256
    private static let zoneCenters: [Float] = [0.1, 0.3, 0.5, 0.7, 0.9]
    private static let zoneWidth: Float = 0.11

    // 参照画像の統計には被写体の色も含まれる。全部を写すと階調が破綻するので、
    // 色味として自然に見える範囲に収める。値は実クリップでの確認から決めた。
    private static let maximumLightnessShift: Float = 0.14
    private static let minimumSlope: Float = 0.55
    private static let maximumSlope: Float = 1.7
    private static let maximumColorShift: Float = 0.035
    private static let chromaGainRange: ClosedRange<Float> = 0.6...1.5

    private struct ZoneTransform {
        var sourceMean = SIMD2<Float>(repeating: 0)
        var offset = SIMD2<Float>(repeating: 0)
        var matrix = simd_float2x2(diagonal: SIMD2(repeating: 1))

        func apply(_ ab: SIMD2<Float>) -> SIMD2<Float> {
            sourceMean + offset + matrix * (ab - sourceMean)
        }
    }

    /// 上限へ滑らかに近づける。小さな値はほとんど変えない。
    private static func softLimit(_ value: Float, limit: Float) -> Float {
        limit * tanh(value / limit)
    }

    /// 隣の領域と平均し、明るさの変化で色が急に跳ねないようにする。
    private static func smoothedZones(_ zones: [ZoneTransform?]) -> [ZoneTransform?] {
        zones.indices.map { index in
            guard var result = zones[index] else { return nil }
            var offset = result.offset * 2
            var column0 = result.matrix.columns.0 * 2
            var column1 = result.matrix.columns.1 * 2
            var total: Float = 2
            for neighbor in [index - 1, index + 1] where zones.indices.contains(neighbor) {
                guard let zone = zones[neighbor] else { continue }
                offset += zone.offset
                column0 += zone.matrix.columns.0
                column1 += zone.matrix.columns.1
                total += 1
            }
            result.offset = offset / total
            result.matrix = simd_float2x2(column0 / total, column1 / total)
            return result
        }
    }

    static func buildLUT(size: Int, transform: (SIMD3<Float>) -> SIMD3<Float>) -> LookLUT {
        var rgba = [Float](repeating: 1, count: size * size * size * 4)
        let scale = 1 / Float(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let color = transform(SIMD3(Float(r) * scale, Float(g) * scale, Float(b) * scale))
                    let offset = ((b * size + g) * size + r) * 4
                    rgba[offset] = color.x
                    rgba[offset + 1] = color.y
                    rgba[offset + 2] = color.z
                }
            }
        }
        return LookLUT(size: size, rgba: rgba)
    }

    /// source の色味を reference に近づける LUT を作る。どちらも sRGB 表示値。
    public static func match(source: [SIMD3<Float>], reference: [SIMD3<Float>], lutSize: Int = 33) -> LookLUT {
        guard !source.isEmpty, !reference.isEmpty else { return .identity(size: lutSize) }

        let sourceLab = source.map(LookOklab.fromSRGB)
        let referenceLab = reference.map(LookOklab.fromSRGB)
        let curve = lightnessCurve(source: sourceLab.map(\.x), reference: referenceLab.map(\.x))

        // 明るさを揃えた後の値で領域を分け、シャドウとハイライトで別の色の傾向を保つ。
        let mappedSource = sourceLab.map { SIMD3(evaluate(curve, $0.x), $0.y, $0.z) }
        let zones = smoothedZones(zoneCenters.indices.map { zone in
            zoneTransform(zone: zone, source: mappedSource, reference: referenceLab)
        })

        return buildLUT(size: lutSize) { color in
            let lab = LookOklab.fromSRGB(color)
            let lightness = evaluate(curve, lab.x)
            let ab = SIMD2(lab.y, lab.z)

            // データのある領域だけを使う。遠い領域しかなくても重みが消えないよう、
            // 距離の基準を最も近い領域に合わせる。
            let available = zoneCenters.indices.filter { zones[$0] != nil }
            guard let nearest = available.min(by: {
                abs(zoneCenters[$0] - lightness) < abs(zoneCenters[$1] - lightness)
            }) else {
                return LookOklab.toSRGBInGamut(SIMD3(lightness, ab.x, ab.y))
            }
            let nearestDistance = abs(zoneCenters[nearest] - lightness)

            var mapped = SIMD2<Float>(repeating: 0)
            var total: Float = 0
            for index in available {
                guard let zone = zones[index] else { continue }
                let distance = (abs(zoneCenters[index] - lightness) - nearestDistance) / zoneWidth
                let weight = exp(-0.5 * distance * distance)
                mapped += zone.apply(ab) * weight
                total += weight
            }
            mapped /= total
            return LookOklab.toSRGBInGamut(SIMD3(lightness, mapped.x, mapped.y))
        }
    }

    private static func zoneWeight(_ zone: Int, lightness: Float) -> Float {
        let distance = (lightness - zoneCenters[zone]) / zoneWidth
        return exp(-0.5 * distance * distance)
    }

    private static func evaluate(_ curve: [Float], _ lightness: Float) -> Float {
        let position = max(0, min(1, lightness)) * Float(curve.count - 1)
        let index = min(Int(position), curve.count - 2)
        let t = position - Float(index)
        return curve[index] + (curve[index + 1] - curve[index]) * t
    }

    /// 累積分布を合わせた明るさのカーブ。階調が壊れないよう傾きを制限する。
    private static func lightnessCurve(source: [Float], reference: [Float]) -> [Float] {
        let sortedSource = source.sorted()
        let sortedReference = reference.sorted()
        var curve = [Float](repeating: 0, count: curveSize)

        for i in 0..<curveSize {
            let lightness = Float(i) / Float(curveSize - 1)
            let rank = lowerBound(sortedSource, lightness)
            let percentile = max(0.002, min(0.998, Float(rank) / Float(sortedSource.count)))
            curve[i] = sortedReference[min(Int(percentile * Float(sortedReference.count)), sortedReference.count - 1)]
        }

        for _ in 0..<3 {
            curve = smoothed(curve, radius: 8)
        }

        // 参照画像の明るさは被写体の違いも含むので、全部は追わない。
        for i in 0..<curveSize {
            let lightness = Float(i) / Float(curveSize - 1)
            curve[i] = lightness + softLimit(curve[i] - lightness, limit: maximumLightnessShift)
        }

        let step = 1 / Float(curveSize - 1)
        var limited = curve
        for i in 1..<curveSize {
            limited[i] = max(limited[i - 1] + minimumSlope * step, min(limited[i - 1] + maximumSlope * step, curve[i]))
        }

        // 傾きの制限で生じた全体のずれを戻す。
        let offset = zip(curve, limited).map { $0 - $1 }.reduce(0, +) / Float(curveSize)
        return limited.map { max(0, min(1, $0 + offset)) }
    }

    private static func lowerBound(_ values: [Float], _ target: Float) -> Int {
        var low = 0
        var high = values.count
        while low < high {
            let middle = (low + high) / 2
            if values[middle] < target { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private static func smoothed(_ values: [Float], radius: Int) -> [Float] {
        values.indices.map { i in
            let lower = max(0, i - radius)
            let upper = min(values.count - 1, i + radius)
            return values[lower...upper].reduce(0, +) / Float(upper - lower + 1)
        }
    }

    private struct ZoneStatistics {
        var weight: Float = 0
        var mean = SIMD2<Float>(repeating: 0)
        var covariance = simd_float2x2(diagonal: SIMD2(repeating: 0))
    }

    private static func statistics(zone: Int, colors: [SIMD3<Float>]) -> ZoneStatistics {
        var result = ZoneStatistics()
        var sum = SIMD2<Float>(repeating: 0)
        for color in colors {
            let weight = zoneWeight(zone, lightness: color.x)
            result.weight += weight
            sum += SIMD2(color.y, color.z) * weight
        }
        guard result.weight > 0 else { return result }
        result.mean = sum / result.weight

        var xx: Float = 0, xy: Float = 0, yy: Float = 0
        for color in colors {
            let weight = zoneWeight(zone, lightness: color.x)
            let delta = SIMD2(color.y, color.z) - result.mean
            xx += weight * delta.x * delta.x
            xy += weight * delta.x * delta.y
            yy += weight * delta.y * delta.y
        }
        let regularization: Float = 0.00002
        result.covariance = simd_float2x2(
            SIMD2(xx / result.weight + regularization, xy / result.weight),
            SIMD2(xy / result.weight, yy / result.weight + regularization)
        )
        return result
    }

    /// 2x2 の対称正定値行列の平方根。
    private static func squareRoot(_ m: simd_float2x2) -> simd_float2x2 {
        let root = sqrt(max(m.determinant, 0))
        let trace = m.columns.0.x + m.columns.1.y
        let scale = sqrt(max(trace + 2 * root, 0.0000001))
        let shifted = simd_float2x2(
            SIMD2(m.columns.0.x + root, m.columns.0.y),
            SIMD2(m.columns.1.x, m.columns.1.y + root)
        )
        return shifted * (1 / scale)
    }

    private static func zoneTransform(zone: Int, source: [SIMD3<Float>], reference: [SIMD3<Float>]) -> ZoneTransform? {
        let s = statistics(zone: zone, colors: source)
        let r = statistics(zone: zone, colors: reference)

        // どちらかにその明るさの領域がほとんどなければ、統計が信用できないので使わない。
        let minimumShare: Float = 0.01
        guard s.weight > Float(source.count) * minimumShare,
              r.weight > Float(reference.count) * minimumShare else {
            return nil
        }

        // 平均と共分散を一致させる最小の線形変換 (Monge-Kantorovich)。
        let sourceRoot = squareRoot(s.covariance)
        let sourceRootInverse = sourceRoot.inverse
        let middle = squareRoot(sourceRoot * r.covariance * sourceRoot)
        let matrix = limitedGain(sourceRootInverse * middle * sourceRootInverse)

        let shift = r.mean - s.mean
        let length = simd_length(shift)
        let offset = length > 0 ? shift * (softLimit(length, limit: maximumColorShift) / length) : shift

        return ZoneTransform(sourceMean: s.mean, offset: offset, matrix: matrix)
    }

    /// 対称行列の固有値を、色の方向ごとの彩度の増減として制限する。
    private static func limitedGain(_ m: simd_float2x2) -> simd_float2x2 {
        let a = m.columns.0.x
        let b = (m.columns.0.y + m.columns.1.x) / 2
        let d = m.columns.1.y
        let halfTrace = (a + d) / 2
        let radius = sqrt(max((a - d) * (a - d) / 4 + b * b, 0))
        let high = halfTrace + radius
        let low = halfTrace - radius

        func clamped(_ value: Float) -> Float {
            max(chromaGainRange.lowerBound, min(chromaGainRange.upperBound, value))
        }

        guard radius > 0.000001 else {
            return simd_float2x2(diagonal: SIMD2(repeating: clamped(halfTrace)))
        }

        // m = high * P + low * (I - P)。P は high の固有ベクトルへの射影。
        let projection = simd_float2x2(
            SIMD2((a - low) / (high - low), b / (high - low)),
            SIMD2(b / (high - low), (d - low) / (high - low))
        )
        let identity = simd_float2x2(diagonal: SIMD2(repeating: 1))
        return projection * clamped(high) + (identity - projection) * clamped(low)
    }

    /// 代表色を明るい順に返す。乱数を使わないので結果は毎回同じになる。
    public static func palette(of colors: [SIMD3<Float>], count: Int = 6) -> [SIMD3<Float>] {
        guard !colors.isEmpty else { return [] }
        let step = max(1, colors.count / 6000)
        let samples = stride(from: 0, to: colors.count, by: step).map { LookOklab.fromSRGB(colors[$0]) }
        let sorted = samples.sorted { $0.x < $1.x }

        var centers = (0..<count).map { sorted[min(sorted.count - 1, ($0 * 2 + 1) * sorted.count / (count * 2))] }
        for _ in 0..<10 {
            var sums = [SIMD3<Float>](repeating: SIMD3(repeating: 0), count: count)
            var counts = [Float](repeating: 0, count: count)
            for sample in samples {
                var best = 0
                var bestDistance = Float.greatestFiniteMagnitude
                for (index, center) in centers.enumerated() {
                    let delta = (sample - center) * SIMD3<Float>(1, 2, 2)
                    let distance = simd_length_squared(delta)
                    if distance < bestDistance {
                        bestDistance = distance
                        best = index
                    }
                }
                sums[best] += sample
                counts[best] += 1
            }
            for index in centers.indices where counts[index] > 0 {
                centers[index] = sums[index] / counts[index]
            }
        }
        return centers.sorted { $0.x < $1.x }.map(LookOklab.toSRGBInGamut)
    }
}
