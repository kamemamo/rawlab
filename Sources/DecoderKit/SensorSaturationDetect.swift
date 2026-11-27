import CoreImage
import Foundation
import ImageIO

/// センサーの飽和の見つけ方(RawLab エンジンと RawLab ネイティブで共通)。
///
/// 白レベル(ファイルやカメラの表に書かれた最大値)ちょうどで飽和するとは限らず、
/// 機種や ISO によっては少し手前で頭打ちになる。そのときは画素の値がある 1 つの値に「積み上がる」ので、
/// 色ごとに「最大値の近くに画素が不自然に集まっているか」を見て、本当の飽和の値を決める。
enum SensorSaturationDetect {
    /// 最大値のこの割合以上を「最大値に積み上がった画素」とみなす
    static let top: Float = 0.998
    /// 比べる帯(最大値の 97%〜99.8%)
    static let band: Float = 0.97
    /// 飽和とみなす: 飽和の値のこの割合以上
    static let threshold: Float = 0.995

    /// 色ごとの集計 [最大値, 最大値の近くの数, 帯の数]
    struct Stats {
        var maxValue: Float = 0
        var topCount = 0
        var bandCount = 0
    }

    /// 0〜1 に正規化した生の値(白レベル = 1)を、色ごとに 2 回なめて飽和の値を求める。
    /// 積み上がりがなければ 1(白レベル)
    static func levels(rows: Int, colors: Int = 3,
                       _ visit: (_ row: Int, _ body: (_ color: Int, _ value: Float) -> Void) -> Void) -> [Float] {
        let lock = NSLock()
        var maxima = [Float](repeating: 0, count: colors)
        DispatchQueue.concurrentPerform(iterations: rows) { row in
            var local = [Float](repeating: 0, count: colors)
            visit(row) { c, v in if v > local[c] { local[c] = v } }
            lock.lock()
            for c in 0..<colors { maxima[c] = max(maxima[c], local[c]) }
            lock.unlock()
        }
        var tops = [Int](repeating: 0, count: colors), bands = [Int](repeating: 0, count: colors)
        let maxCopy = maxima
        DispatchQueue.concurrentPerform(iterations: rows) { row in
            var t = [Int](repeating: 0, count: colors), b = [Int](repeating: 0, count: colors)
            visit(row) { c, v in
                let m = maxCopy[c]
                if v >= m * top { t[c] += 1 } else if v >= m * band { b[c] += 1 }
            }
            lock.lock()
            for c in 0..<colors { tops[c] += t[c]; bands[c] += b[c] }
            lock.unlock()
        }
        return (0..<colors).map { c in
            let m = maxima[c]
            // 積み上がり: 最大値の近く(幅 0.2%)の画素の密度が、その下の帯(幅 2.8%)の 3 倍以上
            let piled = tops[c] >= 16 && Double(tops[c]) * 14 >= 3 * Double(bands[c])
            return piled && m > 0.5 ? min(m, 1) : 1
        }
    }

    /// ブロックごとの飽和(ビット 0 = R、1 = G、2 = B)から、表示用の地図と割合を作る。
    /// 地図は outputSize に引き伸ばし(近い画素の値のまま)、デコード結果と同じ向きにする
    static func makeSaturation(bits: [UInt8], width: Int, height: Int,
                               outputSize: CGSize, orientation: CGImagePropertyOrientation?) -> SensorSaturation {
        var counts = [Int](repeating: 0, count: 3), any = 0
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let b = bits[i]
            guard b != 0 else { continue }
            any += 1
            for c in 0..<3 where b & (1 << c) != 0 {
                counts[c] += 1
                rgba[i * 4 + c] = 255
            }
            rgba[i * 4 + 3] = 255
        }
        let total = Double(max(width * height, 1))
        var map = CIImage(bitmapData: Data(rgba), bytesPerRow: width * 4,
                          size: CGSize(width: width, height: height), format: .RGBA8, colorSpace: nil)
        if CGFloat(width) != outputSize.width || CGFloat(height) != outputSize.height {
            map = map.samplingNearest().transformed(by: CGAffineTransform(
                scaleX: outputSize.width / CGFloat(width), y: outputSize.height / CGFloat(height)))
        }
        if let o = orientation { map = map.oriented(o) }
        return SensorSaturation(map: map, fraction: counts.map { Double($0) / total },
                                anyFraction: Double(any) / total)
    }
}
