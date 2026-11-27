import Foundation

/// 白飛びの復元(RawLab エンジン用)。
///
/// センサーでは R / G / B のうち 1 色だけが先に飽和することが多い。飽和していない色と、
/// 白飛びのまわりの「色合い(各色の割合)」から、飽和した色の本来の値を推定する。
///
/// 1. 白飛びしていない画素を 8×8 のブロックにまとめ、R・G・B の合計を数える
/// 2. プッシュ・プル(粗い段階へ集めてから細かい段階へ戻す)で、
///    色合いを白飛びした範囲の内側まで滑らかに広げる
/// 3. 白飛びに近い画素ごとに、飽和していない色から明るさを見積もり、
///    広げた色合いを掛けて飽和した色を補う(元より暗くはしない)。境目はなめらかに混ぜる
///
/// 入力はホワイトバランス後のカメラ RGB(RGBA)。色ごとの飽和の値は `clip`。
/// 復元した明るさは 1 を超えたまま残す(露出やハイライト圧縮で階調を戻せるように)。
enum HighlightReconstruction {
    static let block = 8
    /// clip に対するこの割合から「白飛びしかけ」とみなし、hi で完全に白飛び
    static let lo: Float = 0.90
    static let hi: Float = 0.98
    /// 色合いを集める画素: どの色も clip の 85% 未満で、白飛びに近い明るさ(合計が clip 合計の 30% 以上)。
    /// 暗い所(木の枝など)の色合いを空の白飛びに持ち込まないため
    static let sampleMax: Float = 0.85
    /// 補うときに使う色合いの、無彩色(各色 1/3)からの偏りの上限(割合)
    static let maxChromaDeviation: Float = 0.25
    static let sampleMinRatio: Float = 0.30

    /// strength(0〜1)で、切り捨て(各色 1 で頭打ち)の結果と復元した結果を混ぜる
    static func reconstruct(_ rgba: inout [Float], _ w: Int, _ h: Int, clip: [Float], strength: Float) {
        let s = min(max(strength, 0), 1)
        guard s < 1 else {
            reconstruct(&rgba, w, h, clip: clip)
            return
        }
        let original = rgba
        if s > 0 { reconstruct(&rgba, w, h, clip: clip) }
        original.withUnsafeBufferPointer { o in
            rgba.withUnsafeMutableBufferPointer { p in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for i in (y * w * 4)..<((y + 1) * w * 4) where i & 3 != 3 {
                        let clipped = min(o[i], 1)
                        p[i] = clipped + s * (p[i] - clipped)
                    }
                }
            }
        }
    }

    static func reconstruct(_ rgba: inout [Float], _ w: Int, _ h: Int, clip: [Float]) {
        let bw = (w + block - 1) / block, bh = (h + block - 1) / block
        let c0 = clip[0], c1 = clip[1], c2 = clip[2]
        let sampleMinSum = (c0 + c1 + c2) * sampleMinRatio

        // 1. ブロックごとの合計(R, G, B, 画素数)
        var sums = [Float](repeating: 0, count: bw * bh * 4)
        rgba.withUnsafeBufferPointer { p in
            sums.withUnsafeMutableBufferPointer { s in
                DispatchQueue.concurrentPerform(iterations: bh) { by in
                    for bx in 0..<bw {
                        var r: Float = 0, g: Float = 0, b: Float = 0, n: Float = 0
                        for y in (by * block)..<min(h, (by + 1) * block) {
                            for x in (bx * block)..<min(w, (bx + 1) * block) {
                                let o = (y * w + x) * 4
                                let R = p[o], G = p[o + 1], B = p[o + 2]
                                if R < c0 * sampleMax, G < c1 * sampleMax, B < c2 * sampleMax,
                                   R + G + B > sampleMinSum {
                                    r += R; g += G; b += B; n += 1
                                }
                            }
                        }
                        let i = (by * bw + bx) * 4
                        s[i] = r; s[i + 1] = g; s[i + 2] = b; s[i + 3] = n
                    }
                }
            }
        }

        // 2. 色合いを白飛びの内側まで広げる
        let chroma = pushPull(sums, bw, bh)

        // 3. 画素ごとに補う
        rgba.withUnsafeMutableBufferPointer { p in
            DispatchQueue.concurrentPerform(iterations: h) { y in
                for x in 0..<w {
                    let o = (y * w + x) * 4
                    // 白飛びに近くない画素はすぐ飛ばす(大半の画素はここで終わる)
                    guard p[o] > c0 * lo || p[o + 1] > c1 * lo || p[o + 2] > c2 * lo else { continue }
                    let v = [p[o], p[o + 1], p[o + 2]]
                    let t = [ramp(v[0] / c0), ramp(v[1] / c1), ramp(v[2] / c2)]

                    var ch = sample(chroma, bw, bh, x, y)
                    // 3 色とも飽和している所は元の色がわからないので、まわりの色合いを薄めて無彩色に寄せる
                    // (濃い色合いのまま明るさを合わせると、色の付いた斑点になる)
                    let allClipped = min(t[0], min(t[1], t[2]))
                    if allClipped > 0 {
                        let k = allClipped  // 完全に飽和していれば無彩色(白)にする
                        for i in 0..<3 { ch[i] = ch[i] * (1 - k) + k / 3 }
                    }
                    // 色合いの偏りに上限をかける。枝の縁の色収差(青紫のにじみ)などが混ざると
                    // 極端な色合いになり、飽和した色を補いすぎて色の付いた斑点になるため。
                    // 飽和していない色が 1 つだけのときは見積もりが不安定なので、さらに控えめにする
                    let unclipped = (t[0] < 0.5 ? 1 : 0) + (t[1] < 0.5 ? 1 : 0) + (t[2] < 0.5 ? 1 : 0)
                    let maxDev: Float = unclipped >= 2 ? maxChromaDeviation : maxChromaDeviation * 0.5
                    let dev = (0..<3).map { ch[$0] - 1 / 3 }
                    let m = dev.map(abs).max()! * 3
                    if m > maxDev {
                        for i in 0..<3 { ch[i] = 1 / 3 + dev[i] * (maxDev / m) }
                    }

                    // 飽和していない色から、明るさ(3 色の合計)を見積もる
                    var num: Float = 0, den: Float = 0
                    for k in 0..<3 {
                        let u = 1 - t[k]
                        num += u * v[k]
                        den += u * ch[k]
                    }
                    // 全部の色が飽和しているときは、どの色も元より暗くならない最小の明るさ
                    var floorSum: Float = 0
                    for k in 0..<3 { floorSum = max(floorSum, v[k] / max(ch[k], 1e-4)) }
                    let sum = den > 0.05 ? max(num / den, 0) : floorSum

                    // 色合いがこの画素の飽和していない色どうしの比と合っているか(信頼度)。
                    // 合わないとき(例: 青みの空なのに、まわりの暖色の壁の色合いを使ってしまう)は、
                    // 「無彩色に近い」とみなす見積もり(飽和していない色の平均)に寄せる
                    var mismatch: Float = 0, pairs: Float = 0
                    for i in 0..<3 where t[i] < 0.5 {
                        for j in (i + 1)..<3 where t[j] < 0.5 && v[i] > 0 && v[j] > 0 {
                            mismatch += abs(log((v[i] / v[j]) / max(ch[i] / max(ch[j], 1e-4), 1e-4)))
                            pairs += 1
                        }
                    }
                    let confidence: Float = pairs > 0 ? exp(-3 * mismatch / pairs) : (den > 0.05 ? 0.5 : 1)
                    var grayNum: Float = 0, grayDen: Float = 0
                    for k in 0..<3 { grayNum += (1 - t[k]) * v[k]; grayDen += 1 - t[k] }
                    let gray = grayDen > 0.05 ? grayNum / grayDen : 0

                    var out = [Float](repeating: 0, count: 3)
                    for k in 0..<3 {
                        let byChroma = ch[k] * sum
                        let estimate = grayDen > 0.05 ? confidence * byChroma + (1 - confidence) * gray : byChroma
                        let rebuilt = max(v[k], estimate)
                        out[k] = v[k] + t[k] * (rebuilt - v[k])
                    }
                    // 緑が飽和しているのに赤・青の両方より低いとマゼンタになるので、少なくとも低い方まで上げる
                    if t[1] > 0 {
                        out[1] = max(out[1], t[1] * min(out[0], out[2]) + (1 - t[1]) * out[1])
                    }
                    p[o] = out[0]; p[o + 1] = out[1]; p[o + 2] = out[2]
                }
            }
        }
    }

    /// clip に対する割合 → 0(白飛びしていない)〜 1(白飛び)を滑らかに
    @inline(__always)
    static func ramp(_ ratio: Float) -> Float {
        let x = min(max((ratio - lo) / (hi - lo), 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// プッシュ・プル: 合計を 2×2 ずつまとめて粗い段階を作り、上から下へ
    /// 「自分のブロックに十分な画素があればその色合い、なければ親の色合い」を混ぜて戻す
    static func pushPull(_ sums: [Float], _ w: Int, _ h: Int) -> [Float] {
        var levels: [(data: [Float], w: Int, h: Int)] = [(sums, w, h)]
        while levels.last!.w > 1 || levels.last!.h > 1 {
            let (src, sw, sh) = levels.last!
            let nw = (sw + 1) / 2, nh = (sh + 1) / 2
            var dst = [Float](repeating: 0, count: nw * nh * 4)
            for y in 0..<sh {
                for x in 0..<sw {
                    let i = (y * sw + x) * 4, j = ((y / 2) * nw + x / 2) * 4
                    for k in 0..<4 { dst[j + k] += src[i + k] }
                }
            }
            levels.append((dst, nw, nh))
        }

        func own(_ d: [Float], _ i: Int) -> [Float]? {
            let s = d[i] + d[i + 1] + d[i + 2]
            return s > 0 ? [d[i] / s, d[i + 1] / s, d[i + 2] / s] : nil
        }
        // いちばん上(1×1)
        let top = levels.last!
        var parent = own(top.data, 0) ?? [1 / 3, 1 / 3, 1 / 3]
        var parentGrid = parent
        var pw = 1, ph = 1
        let pseudo: Float = 2  // 画素が少ないブロックは親の色合いに寄せる
        for level in levels.dropLast().reversed() {
            var grid = [Float](repeating: 0, count: level.w * level.h * 3)
            for y in 0..<level.h {
                for x in 0..<level.w {
                    // 親の色合いは双一次補間で取る(そのまま使うとブロックの境目で段差になる)
                    parent = sample(parentGrid, pw, ph, (Float(x) + 0.5) / 2 - 0.5, (Float(y) + 0.5) / 2 - 0.5)
                    let i = (y * level.w + x) * 4
                    let n = level.data[i + 3]
                    let c: [Float]
                    if let o = own(level.data, i) {
                        let a = n / (n + pseudo)
                        c = (0..<3).map { o[$0] * a + parent[$0] * (1 - a) }
                    } else {
                        c = parent
                    }
                    let g = (y * level.w + x) * 3
                    grid[g] = c[0]; grid[g + 1] = c[1]; grid[g + 2] = c[2]
                }
            }
            parentGrid = grid
            pw = level.w
            ph = level.h
        }
        return parentGrid
    }

    /// ブロックの中心を基準に、色合いを双一次補間で取り出す(画素の位置から)
    @inline(__always)
    static func sample(_ c: [Float], _ bw: Int, _ bh: Int, _ x: Int, _ y: Int) -> [Float] {
        sample(c, bw, bh, (Float(x) + 0.5) / Float(block) - 0.5, (Float(y) + 0.5) / Float(block) - 0.5)
    }

    /// 格子の座標(小数)で双一次補間
    @inline(__always)
    static func sample(_ c: [Float], _ bw: Int, _ bh: Int, _ gx: Float, _ gy: Float) -> [Float] {
        let fx = min(max(gx, 0), Float(bw - 1))
        let fy = min(max(gy, 0), Float(bh - 1))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(x0 + 1, bw - 1), y1 = min(y0 + 1, bh - 1)
        let ax = fx - Float(x0), ay = fy - Float(y0)
        var out = [Float](repeating: 0, count: 3)
        for k in 0..<3 {
            let a = c[(y0 * bw + x0) * 3 + k], b = c[(y0 * bw + x1) * 3 + k]
            let d = c[(y1 * bw + x0) * 3 + k], e = c[(y1 * bw + x1) * 3 + k]
            out[k] = (a * (1 - ax) + b * ax) * (1 - ay) + (d * (1 - ax) + e * ax) * ay
        }
        return out
    }
}
