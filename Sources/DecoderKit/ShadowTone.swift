import CoreImage
import Foundation

/// シャドウ: ヒストグラム(sRGB の明るさ)の左から range までの暗い所だけを持ち上げる・沈める。
///
/// - 明るさ L(sRGB ガンマ、0〜1)を L + 強さ × 係数 × range × x(1−x)²(x = L / range)に動かす。
///   0(真っ黒)と range では動かず、range より明るい所はまったく変わらない。いちばん動くのは range の 1/3 のあたり
/// - 係数は持ち上げ 2.4・沈め 0.9(どちらも明るさの順番が入れ替わらない範囲)
/// - 色は変えず、明るさの比で R・G・B をそろえて動かす
enum ShadowTone {
    static let dimension = 64
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Data] = [:]

    /// 明るさ(sRGB ガンマ)の対応
    static func curve(_ l: Double, amount: Double, range: Double) -> Double {
        guard range > 0, l > 0, l < range else { return l }
        let x = l / range
        let gain = amount > 0 ? 2.4 : 0.9
        return l + amount * gain * range * x * (1 - x) * (1 - x)
    }

    static func apply(_ image: CIImage, amount: Double, range: Double) -> CIImage {
        image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": dimension,
            "inputCubeData": data(amount: amount, range: range),
            "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!,
        ])
    }

    private static func data(amount: Double, range: Double) -> Data {
        let key = "\(amount)-\(range)"
        lock.lock()
        if let d = cache[key] {
            lock.unlock()
            return d
        }
        lock.unlock()
        let d = build(amount: amount, range: range)
        lock.lock()
        if cache.count > 64 { cache.removeAll() }
        cache[key] = d
        lock.unlock()
        return d
    }

    private static func build(amount: Double, range: Double) -> Data {
        let n = dimension
        var cube = [Float](repeating: 1, count: n * n * n * 4)
        cube.withUnsafeMutableBufferPointer { p in
            DispatchQueue.concurrentPerform(iterations: n) { bi in
                for gi in 0..<n {
                    for ri in 0..<n {
                        let d = Double(n - 1)
                        let sr = Double(ri) / d, sg = Double(gi) / d, sb = Double(bi) / d
                        let lr = OKLab.srgbToLinear(sr), lg = OKLab.srgbToLinear(sg), lb = OKLab.srgbToLinear(sb)
                        let y = 0.2126 * lr + 0.7152 * lg + 0.0722 * lb
                        var out = (sr, sg, sb)
                        if y > 0 {
                            let l = OKLab.linearToSRGB(y)
                            let moved = curve(l, amount: amount, range: range)
                            if moved != l {
                                let k = OKLab.srgbToLinear(min(max(moved, 0), 1)) / y
                                func back(_ v: Double) -> Double { OKLab.linearToSRGB(min(max(v * k, 0), 1)) }
                                out = (back(lr), back(lg), back(lb))
                            }
                        }
                        let i = ((bi * n + gi) * n + ri) * 4
                        p[i] = Float(out.0); p[i + 1] = Float(out.1); p[i + 2] = Float(out.2); p[i + 3] = 1
                    }
                }
            }
        }
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
