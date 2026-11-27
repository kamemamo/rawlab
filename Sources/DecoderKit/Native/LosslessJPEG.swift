import Foundation

/// ロスレス JPEG(ITU-T T.81 の SOF3)を展開する自前の実装。DNG の RAW 本体の多くがこの形式。
///
/// 各サンプルは「近くのサンプルから予測した値」との差がハフマン符号で並んでいる。
/// 予測のしかたは SOS の Ss(1〜7)で決まる。複数の成分(Nf)は 1 画素の中で交互に並ぶ。
/// 展開したサンプルは並んだ順に、呼び出し側が渡す幅で折り返して書き込む
/// (DNG では JPEG の幅 × 成分数 = タイルの幅、となっていることが多い)。
enum LosslessJPEG {
    enum Failure: LocalizedError {
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let m): "ロスレス JPEG を展開できません: \(m)"
            }
        }
    }

    /// ハフマン表。先頭 16 ビットで引くと (符号の長さ << 8 | 値) が返る
    private struct Huffman {
        var table = [UInt16](repeating: 0, count: 1 << 16)

        init(counts: [Int], symbols: [UInt8]) throws {
            var code = 0, k = 0
            for len in 1...16 {
                for _ in 0..<counts[len - 1] {
                    guard k < symbols.count else { throw Failure.invalid("ハフマン表が足りません") }
                    let shift = 16 - len
                    let start = code << shift, n = 1 << shift
                    guard start + n <= table.count else { throw Failure.invalid("ハフマン表が壊れています") }
                    let entry = UInt16(len << 8) | UInt16(symbols[k])
                    for i in start..<(start + n) { table[i] = entry }
                    code += 1
                    k += 1
                }
                code <<= 1
            }
        }
    }

    /// `bytes[start..<end]` にあるロスレス JPEG を展開し、`out` の (x0, y0) から
    /// 幅 `width`・高さ `height` の範囲に、`stride` 幅の行として書き込む。
    /// サンプルは `wrap` 個ごとに次の行へ折り返す(タイルの幅)。範囲の外に出るサンプルは捨てる
    static func decode(
        _ bytes: UnsafeBufferPointer<UInt8>, start: Int, end: Int,
        into out: UnsafeMutableBufferPointer<UInt16>, stride: Int,
        x0: Int, y0: Int, width: Int, height: Int, wrap: Int
    ) throws {
        var pos = start
        func u8() throws -> Int {
            guard pos < end else { throw Failure.invalid("データが途中で切れています") }
            defer { pos += 1 }
            return Int(bytes[pos])
        }
        func u16() throws -> Int { try u8() << 8 | u8() }

        guard try u16() == 0xFFD8 else { throw Failure.invalid("SOI がありません") }
        var tables = [Huffman?](repeating: nil, count: 4)
        var precision = 0, jpegHeight = 0, jpegWidth = 0
        var componentIDs: [Int] = []
        var restart = 0

        // SOS までのマーカーを読む
        var scanTables: [Int] = []
        var predictor = 1, pointTransform = 0
        markers: while true {
            var marker = try u8()
            guard marker == 0xFF else { throw Failure.invalid("マーカーがありません") }
            while marker == 0xFF { marker = try u8() }
            let length = try u16()
            let segmentEnd = pos + length - 2
            guard segmentEnd <= end else { throw Failure.invalid("セグメントが途中で切れています") }
            switch marker {
            case 0xC4:  // DHT
                while pos < segmentEnd {
                    let info = try u8()
                    let id = info & 15
                    guard info >> 4 == 0, id < 4 else { throw Failure.invalid("想定外のハフマン表(\(info))") }
                    let counts = try (0..<16).map { _ in try u8() }
                    let symbols = try (0..<counts.reduce(0, +)).map { _ in UInt8(try u8()) }
                    tables[id] = try Huffman(counts: counts, symbols: symbols)
                }
            case 0xC3:  // SOF3(ロスレス)
                precision = try u8()
                jpegHeight = try u16()
                jpegWidth = try u16()
                let n = try u8()
                componentIDs = []
                for _ in 0..<n {
                    componentIDs.append(try u8())
                    let sampling = try u8()
                    _ = try u8()
                    guard sampling == 0x11 else { throw Failure.invalid("間引きのある成分には未対応") }
                }
            case 0xC0, 0xC1, 0xC2, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF:
                throw Failure.invalid("ロスレス(SOF3)以外の JPEG(0xFF\(String(marker, radix: 16, uppercase: true)))")
            case 0xDD:  // DRI
                restart = try u16()
            case 0xDA:  // SOS
                let n = try u8()
                guard n == componentIDs.count else { throw Failure.invalid("成分の数が SOF と合いません") }
                for _ in 0..<n {
                    let id = try u8()
                    let t = try u8() >> 4
                    guard componentIDs.contains(id), t < 4, tables[t] != nil else {
                        throw Failure.invalid("ハフマン表が見つかりません")
                    }
                    scanTables.append(t)
                }
                predictor = try u8()
                _ = try u8()
                pointTransform = try u8() & 15
                pos = segmentEnd
                break markers
            default:
                break
            }
            pos = segmentEnd
        }
        let comps = componentIDs.count
        guard comps > 0, jpegWidth > 0, jpegHeight > 0, (2...16).contains(precision), (1...7).contains(predictor)
        else { throw Failure.invalid("SOF / SOS の値が想定外です") }
        let rowSamples = jpegWidth * comps
        if restart > 0, restart % jpegWidth != 0 {
            throw Failure.invalid("行の途中で区切られるリスタートには未対応")
        }

        // ここからエントロピー符号のビット列。FF 00 は FF、FF xx はマーカー
        var buffer: UInt64 = 0
        var count = 0
        var hitMarker = false
        @inline(__always) func fill() {
            while count <= 56 {
                var byte: UInt64 = 0
                if !hitMarker, pos < end {
                    let b = bytes[pos]
                    if b == 0xFF {
                        let next = pos + 1 < end ? bytes[pos + 1] : 0xD9
                        if next == 0 {
                            byte = 0xFF
                            pos += 2
                        } else {
                            hitMarker = true  // マーカーの手前で止まる(以降は 0 を詰める)
                        }
                    } else {
                        byte = UInt64(b)
                        pos += 1
                    }
                }
                buffer |= byte << UInt64(56 - count)
                count += 8
            }
        }
        /// リスタートマーカー(FF D0〜D7)を読み飛ばして、ビットの読み出しをやり直す
        func skipRestart() throws {
            buffer = 0
            count = 0
            hitMarker = false
            while pos + 1 < end, !(bytes[pos] == 0xFF && (0xD0...0xD7).contains(bytes[pos + 1])) { pos += 1 }
            guard pos + 1 < end else { throw Failure.invalid("リスタートマーカーが見つかりません") }
            pos += 2
        }

        let huff = scanTables.map { tables[$0]! }
        let initial = 1 << (precision - pointTransform - 1)
        let mask = (1 << precision) - 1
        // 1 つ前の行と今の行(成分は交互に並ぶ)
        var previous = [Int](repeating: 0, count: rowSamples)
        var current = [Int](repeating: 0, count: rowSamples)
        var sampleIndex = 0  // これまでに出したサンプルの数(折り返し用)
        var bad = false

        do {
            for row in 0..<jpegHeight {
                let restartHere = restart > 0 && row > 0 && (row * jpegWidth) % restart == 0
                if restartHere { try skipRestart() }
                // 先頭の行(リスタートの直後を含む)は上の行がないので、左だけで予測する
                let firstLine = row == 0 || restartHere
                for col in 0..<jpegWidth {
                    for c in 0..<comps {
                        fill()
                        let entry = huff[c].table[Int(buffer >> 48)]
                        let codeLength = Int(entry >> 8)
                        if codeLength == 0 { bad = true }
                        buffer <<= UInt64(codeLength)
                        count -= codeLength
                        let len = Int(entry & 0xFF)
                        var diff = 0
                        if len == 16 {
                            diff = -32768
                        } else if len > 0 {
                            diff = Int(buffer >> UInt64(64 - len))
                            buffer <<= UInt64(len)
                            count -= len
                            if diff & (1 << (len - 1)) == 0 { diff -= (1 << len) - 1 }
                        }

                        let i = col * comps + c
                        let pred: Int
                        if firstLine {
                            pred = col == 0 ? initial : current[i - comps]
                        } else if col == 0 {
                            pred = previous[i]
                        } else {
                            let a = current[i - comps], b = previous[i], cc = previous[i - comps]
                            switch predictor {
                            case 1: pred = a
                            case 2: pred = b
                            case 3: pred = cc
                            case 4: pred = a + b - cc
                            case 5: pred = a + ((b - cc) >> 1)
                            case 6: pred = b + ((a - cc) >> 1)
                            default: pred = (a + b) >> 1
                            }
                        }
                        let value = (pred + diff) & 0xFFFF
                        if value > mask { bad = true }
                        current[i] = value

                        // 折り返して書き込む
                        let ty = sampleIndex / wrap, tx = sampleIndex % wrap
                        sampleIndex += 1
                        if tx < width, ty < height {
                            out[(y0 + ty) * stride + x0 + tx] = UInt16(truncatingIfNeeded: value << pointTransform)
                        }
                    }
                }
                swap(&previous, &current)
            }
        }
        if bad { throw Failure.invalid("値が範囲を超えました(データが壊れている可能性)") }
    }
}
