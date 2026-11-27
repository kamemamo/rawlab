import Foundation

/// 写真から測ったノイズの大きさに合わせた、暗部のノイズ低減(RawLab エンジン・RawLab ネイティブ)。
///
/// 1. 明るさ(Y)と色差(R−G、B−G)に分ける
/// 2. 8×8 のブロックごとに「隣どうしの差のばらつき」を測り、ブロックの明るさごとに集める。
///    模様のあるブロックはばらつきが大きくなるので、各明るさで小さい方(下から 20%)を「ノイズ」とみなし、
///    ノイズの分散 = a × 明るさ + b(光の粒の揺れ + 読み出しの揺れ)の形に当てはめる
/// 3. ガイデッドフィルター(自分自身を手がかりにする)で、まわりのばらつきが「その明るさのノイズ」程度の所だけを
///    なめらかにする。境目や模様(ばらつきがノイズより大きい所)は残る
/// 4. 暗い所ほど強く、明るい所ほど弱く混ぜる
///
/// 入力はリニア sRGB の RGBA。戻り値は黒のあたりの明るさのノイズ(標準偏差、白 = 1)
enum ShadowDenoise {
    static let block = 8

    @discardableResult
    static func apply(_ rgba: inout [Float], _ w: Int, _ h: Int, strength: Float, halfSize: Bool) -> Float? {
        guard w > 32, h > 32, strength > 0 else { return nil }
        let n = w * h
        var y = [Float](repeating: 0, count: n)
        var c1 = [Float](repeating: 0, count: n)
        var c2 = [Float](repeating: 0, count: n)
        rgba.withUnsafeBufferPointer { p in
            y.withUnsafeMutableBufferPointer { yp in
                c1.withUnsafeMutableBufferPointer { p1 in
                    c2.withUnsafeMutableBufferPointer { p2 in
                        DispatchQueue.concurrentPerform(iterations: h) { row in
                            for i in (row * w)..<((row + 1) * w) {
                                let r = p[i * 4], g = p[i * 4 + 1], b = p[i * 4 + 2]
                                yp[i] = (r + 2 * g + b) * 0.25
                                p1[i] = r - g
                                p2[i] = b - g
                            }
                        }
                    }
                }
            }
        }

        let lumaModel = noiseModel(y, guide: y, w, h)
        let model1 = noiseModel(c1, guide: y, w, h)
        let model2 = noiseModel(c2, guide: y, w, h)

        let lumaRadius = halfSize ? 1 : 2
        let chromaRadius = halfSize ? 3 : 6
        // 明るさの目安(ノイズの大きさと、暗部の重みを決める)
        let meanY = box(y, w, h, chromaRadius)
        filter(&y, meanY: meanY, w, h, radius: lumaRadius, model: lumaModel, k: 3, strength: strength)
        filter(&c1, meanY: meanY, w, h, radius: chromaRadius, model: model1, k: 6, strength: strength)
        filter(&c2, meanY: meanY, w, h, radius: chromaRadius, model: model2, k: 6, strength: strength)

        let (yy, cc1, cc2) = (y, c1, c2)
        rgba.withUnsafeMutableBufferPointer { p in
            DispatchQueue.concurrentPerform(iterations: h) { row in
                for i in (row * w)..<((row + 1) * w) {
                    let g = yy[i] - (cc1[i] + cc2[i]) * 0.25
                    p[i * 4] = cc1[i] + g
                    p[i * 4 + 1] = g
                    p[i * 4 + 2] = cc2[i] + g
                }
            }
        }
        return lumaModel.b.squareRoot()
    }

    /// ノイズの分散 = a × 明るさ + b
    struct Model {
        var a: Float
        var b: Float

        @inline(__always) func variance(_ brightness: Float) -> Float { max(a * max(brightness, 0) + b, 1e-12) }
    }

    /// x のノイズを、guide(明るさ)の関数として測る
    static func noiseModel(_ x: [Float], guide: [Float], _ w: Int, _ h: Int) -> Model {
        let bw = (w - 2) / block, bh = (h - 2) / block
        var means = [Float](repeating: 0, count: bw * bh)
        var vars = [Float](repeating: 0, count: bw * bh)
        x.withUnsafeBufferPointer { p in
          guide.withUnsafeBufferPointer { g in
            means.withUnsafeMutableBufferPointer { meansP in
              vars.withUnsafeMutableBufferPointer { varsP in
                DispatchQueue.concurrentPerform(iterations: bh) { by in
                    for bx in 0..<bw {
                        var m: Float = 0, s: Float = 0, s2: Float = 0
                        for yy in 0..<block {
                            let row = 1 + by * block + yy
                            for xx in 0..<block {
                                let i = row * w + 1 + bx * block + xx
                                m += g[i]
                                // 上下左右の平均との差(白いノイズなら分散は元の 1.25 倍)
                                let r = p[i] - 0.25 * (p[i - 1] + p[i + 1] + p[i - w] + p[i + w])
                                s += r
                                s2 += r * r
                            }
                        }
                        let k = Float(block * block)
                        meansP[by * bw + bx] = m / k
                        varsP[by * bw + bx] = max(s2 / k - (s / k) * (s / k), 0) / 1.25
                    }
                }
              }
            }
          }
        }
        // 明るさ(2 のべき)ごとに集める
        let bins = 32
        var buckets = [[Float]](repeating: [], count: bins)
        var centers = [Double](repeating: 0, count: bins)
        for i in 0..<means.count {
            let m = means[i]
            guard m < 0.6 else { continue }  // 飽和に近い所は使わない
            let b = min(max(Int((log2(max(m, 1e-6)) + 20) * 1.5), 0), bins - 1)
            buckets[b].append(vars[i])
            centers[b] += Double(m)
        }
        var points: [(m: Double, v: Double, n: Double)] = []
        for b in 0..<bins where buckets[b].count >= 16 {
            let sorted = buckets[b].sorted()
            // 下から 10%(模様のないブロック)。64 画素の分散の下から 10% は本当の分散の 0.82 倍ほどなので補う
            let v = Double(sorted[sorted.count / 10]) * 1.22
            points.append((centers[b] / Double(buckets[b].count), v, Double(sorted.count)))
        }
        guard !points.isEmpty else { return Model(a: 0, b: 1e-8) }
        if points.count == 1 { return Model(a: 0, b: Float(points[0].v)) }
        // 重み付きの最小二乗で直線に当てはめる
        var sw = 0.0, sm = 0.0, sv = 0.0, smm = 0.0, smv = 0.0
        for p in points {
            let wgt = p.n.squareRoot()
            sw += wgt; sm += wgt * p.m; sv += wgt * p.v; smm += wgt * p.m * p.m; smv += wgt * p.m * p.v
        }
        let det = sw * smm - sm * sm
        var a = det > 0 ? (sw * smv - sm * sv) / det : 0
        a = max(a, 0)
        // 黒のあたりの値は、いちばん暗い明るさで測った値を超えない(模様の多い写真で大きく出すぎないように)
        let darkest = points.min { $0.m < $1.m }!.v
        let b = min(max((sv - a * sm) / sw, points.map(\.v).min()! * 0.25), darkest)
        return Model(a: Float(a), b: Float(b))
    }

    /// ガイデッドフィルター(自分自身を手がかりにする)。
    /// まわりのばらつきが「その明るさで期待されるノイズ」程度なら平らにし、それより大きければ残す
    static func filter(_ x: inout [Float], meanY: [Float], _ w: Int, _ h: Int,
                       radius: Int, model: Model, k: Float, strength: Float) {
        let n = w * h
        let mean = box(x, w, h, radius)
        var sq = [Float](repeating: 0, count: n)
        x.withUnsafeBufferPointer { p in
            sq.withUnsafeMutableBufferPointer { q in
                DispatchQueue.concurrentPerform(iterations: h) { row in
                    for i in (row * w)..<((row + 1) * w) { q[i] = p[i] * p[i] }
                }
            }
        }
        let meanSq = box(sq, w, h, radius)
        var a = [Float](repeating: 0, count: n)
        var b = [Float](repeating: 0, count: n)
        a.withUnsafeMutableBufferPointer { ap in
            b.withUnsafeMutableBufferPointer { bp in
                DispatchQueue.concurrentPerform(iterations: h) { row in
                    for i in (row * w)..<((row + 1) * w) {
                        let variance = max(meanSq[i] - mean[i] * mean[i], 0)
                        let eps = k * model.variance(meanY[i])
                        let ai = variance / (variance + eps)
                        ap[i] = ai
                        bp[i] = mean[i] * (1 - ai)
                    }
                }
            }
        }
        let meanA = box(a, w, h, radius)
        let meanB = box(b, w, h, radius)
        x.withUnsafeMutableBufferPointer { p in
            DispatchQueue.concurrentPerform(iterations: h) { row in
                for i in (row * w)..<((row + 1) * w) {
                    let filtered = meanA[i] * p[i] + meanB[i]
                    // 暗いほど強く(18% グレーで半分)
                    let m = max(meanY[i], 0) / 0.18
                    let weight = strength / (1 + m * m)
                    p[i] += weight * (filtered - p[i])
                }
            }
        }
    }

    /// 半径 r の箱の平均(端は中にある画素だけで平均)
    static func box(_ src: [Float], _ w: Int, _ h: Int, _ r: Int) -> [Float] {
        var tmp = [Float](repeating: 0, count: w * h)
        var out = [Float](repeating: 0, count: w * h)
        // 横
        src.withUnsafeBufferPointer { s in
            tmp.withUnsafeMutableBufferPointer { t in
                DispatchQueue.concurrentPerform(iterations: h) { row in
                    let base = row * w
                    var sum: Float = 0
                    for x in 0..<min(r, w) { sum += s[base + x] }
                    for x in 0..<w {
                        if x + r < w { sum += s[base + x + r] }
                        if x - r - 1 >= 0 { sum -= s[base + x - r - 1] }
                        let count = min(x + r, w - 1) - max(x - r, 0) + 1
                        t[base + x] = sum / Float(count)
                    }
                }
            }
        }
        // 縦(列を何本かずつまとめて、上から順に足し引きする)
        let stripes = 16
        tmp.withUnsafeBufferPointer { t in
            out.withUnsafeMutableBufferPointer { o in
                DispatchQueue.concurrentPerform(iterations: stripes) { k in
                    let x0 = w * k / stripes, x1 = w * (k + 1) / stripes
                    guard x0 < x1 else { return }
                    var sums = [Float](repeating: 0, count: x1 - x0)
                    for yy in 0..<min(r, h) {
                        for x in x0..<x1 { sums[x - x0] += t[yy * w + x] }
                    }
                    for y in 0..<h {
                        let add = y + r < h ? y + r : -1
                        let sub = y - r - 1
                        let count = Float(min(y + r, h - 1) - max(y - r, 0) + 1)
                        for x in x0..<x1 {
                            if add >= 0 { sums[x - x0] += t[add * w + x] }
                            if sub >= 0 { sums[x - x0] -= t[sub * w + x] }
                            o[y * w + x] = sums[x - x0] / count
                        }
                    }
                }
            }
        }
        return out
    }
}
