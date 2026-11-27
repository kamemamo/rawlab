import Foundation

/// ニコンの NEF を自前で読む。
/// TIFF の IFD から RAW 本体の場所・サイズ・色配置を、EXIF とメーカーノートから
/// 黒レベル・撮影時の WB・圧縮の予測値などを取り出し、ロスレス圧縮を展開する。
///
/// 対応: 圧縮(非可逆)・ロスレス圧縮・非圧縮(1 画素 16bit で並べたもの)の 12 / 14bit の NEF。
/// 非圧縮で 12bit を詰めて並べた形はまだ読まない。
struct NikonNEF {
    let make: String
    let model: String
    /// TIFF の Orientation(1〜8)
    let orientation: Int
    let width: Int
    let height: Int
    let bitsPerSample: Int
    /// 2×2 の色配置 [左上, 右上, 左下, 右下]。0=R 1=G 2=B
    let cfa: [Int]
    /// RAW 本体の TIFF の Compression(34713 = ニコン独自の圧縮、1 = 非圧縮)
    let compression: Int
    /// メーカーノートの NEFCompression(1 = 圧縮・タイプ 1、3 = ロスレス、4 = 圧縮・タイプ 2 など)
    let nefCompression: Int?
    let dataOffset: Int
    let dataLength: Int
    /// メーカーノート 0x0096(NEF の展開に使う予測の初期値)の位置
    let linearizationOffset: Int?
    /// メーカーノート 0x003D の黒レベル(R, G, G, B の順)
    let blackLevel: [Int]?
    /// メーカーノート 0x000C の撮影時 WB(R と B の倍率、緑 = 1)
    let asShotRB: (r: Double, b: Double)?
    let exif: ExifValues
    /// メーカーノートの中の TIFF のバイト順
    let makerNoteLittleEndian: Bool
    /// ファイル本体の TIFF のバイト順(非圧縮の画素の並びもこれに従う)
    let fileLittleEndian: Bool
    /// ファイル全体(メモリにマップしたもの)
    let rawData: Data

    struct ExifValues {
        var exposureTime: Double = 0
        var fNumber: Double = 0
        var iso: Double = 0
        var focalLength: Double = 0
        var dateTimeOriginal: String?
        var lensModel: String?
        /// メーカーノート 0x0084(最短・最長焦点距離、開放 F 値の最小・最大)
        var nikonLens: [Double]?
        var pictureControl: String?
        var activeDLighting: Int?
    }

    enum Failure: LocalizedError {
        case notNEF(String)
        case corrupt(String)

        var errorDescription: String? {
            switch self {
            case .notNEF(let m), .corrupt(let m): m
            }
        }
    }

    // MARK: - 解析

    init(data: Data) throws {
        let tiff: TIFFReader
        do { tiff = try TIFFReader(data: data) } catch { throw Failure.notNEF("TIFF 形式ではありません") }
        let chain = tiff.chain()
        guard let ifd0 = chain.first else { throw Failure.notNEF("IFD が読めません") }

        make = ifd0[271].map(tiff.string) ?? ""
        model = ifd0[272].map(tiff.string) ?? ""
        orientation = (ifd0[274].flatMap { try? tiff.int($0) }) ?? 1

        // RAW 本体の IFD を探す(IFD0・その SubIFD・後ろに続く IFD の中で、
        // NewSubfileType = 0 かつ PhotometricInterpretation = CFA のもの)
        var candidates = chain
        for d in chain {
            if let sub = d[330] {
                candidates += tiff.ints(sub).compactMap { try? tiff.ifd(at: $0) }
            }
        }
        guard let rawIFD = candidates.first(where: { d in
            (d[254].flatMap { try? tiff.int($0) } ?? 0) == 0
                && (d[262].flatMap { try? tiff.int($0) }) == 32803
        }) else { throw Failure.notNEF("RAW 本体(CFA の画像)が見つかりません") }

        func int(_ tag: Int, _ d: TIFFReader.IFD = rawIFD) throws -> Int {
            guard let e = d[tag] else { throw Failure.notNEF("タグ \(tag) がありません") }
            return try tiff.int(e)
        }
        width = try int(256)
        height = try int(257)
        bitsPerSample = try int(258)
        compression = try int(259)
        dataOffset = try int(273)
        dataLength = try int(279)

        // CFA の色配置(CFARepeatPatternDim = 2×2 のみ)
        let dim = rawIFD[33421].map(tiff.ints) ?? [2, 2]
        let pattern = rawIFD[33422].map(tiff.ints) ?? []
        guard dim == [2, 2], pattern.count == 4, pattern.allSatisfy({ (0...2).contains($0) }) else {
            throw Failure.notNEF("2×2 のベイヤー配列ではありません")
        }
        cfa = pattern

        // EXIF とメーカーノート
        var exif = ExifValues()
        var nefCompression: Int?
        var linearizationOffset: Int?
        var blackLevel: [Int]?
        var asShotRB: (Double, Double)?
        var makerNoteLittleEndian = tiff.littleEndian
        if let exifPointer = ifd0[34665], let exifIFD = try? tiff.ifd(at: tiff.int(exifPointer)) {
            exif.exposureTime = exifIFD[33434].flatMap { try? tiff.real($0) } ?? 0
            exif.fNumber = exifIFD[33437].flatMap { try? tiff.real($0) } ?? 0
            exif.iso = exifIFD[34855].flatMap { try? tiff.real($0) } ?? 0
            exif.focalLength = exifIFD[37386].flatMap { try? tiff.real($0) } ?? 0
            exif.dateTimeOriginal = exifIFD[36867].map(tiff.string)
            exif.lensModel = exifIFD[42036].map(tiff.string)

            // ニコンのメーカーノート(タイプ 3): "Nikon\0" + 版 4 バイト のあとに TIFF ヘッダーが続き、
            // 中のオフセットはその TIFF ヘッダーの先頭から数える
            if let note = exifIFD[37500],
               let head = tiff.bytes(TIFFReader.Entry(tag: 0, type: 7, count: 6, valueOffset: note.valueOffset)),
               head == Data("Nikon\0".utf8),
               let mn = try? TIFFReader(data: data, headerAt: note.valueOffset + 10),
               let notes = try? mn.ifd(at: mn.firstIFDOffset) {
                makerNoteLittleEndian = mn.littleEndian
                nefCompression = notes[0x0093].flatMap { try? mn.int($0) }
                linearizationOffset = notes[0x0096]?.valueOffset
                if let e = notes[0x003D], e.count == 4 { blackLevel = mn.ints(e) }
                if let e = notes[0x000C], e.count >= 2,
                   let r = try? mn.real(e, 0), let b = try? mn.real(e, 1), r > 0, b > 0 {
                    asShotRB = (r, b)
                }
                if let e = notes[0x0084], e.count == 4 {
                    exif.nikonLens = (0..<4).compactMap { try? mn.real(e, $0) }
                }
                // ピクチャーコントロール: 版 4 バイト + 名前 20 バイト
                if let e = notes[0x0023], let d = mn.bytes(e), d.count >= 24 {
                    let name = String(decoding: d.dropFirst(4).prefix(20).prefix { $0 != 0 }, as: UTF8.self)
                        .trimmingCharacters(in: .whitespaces)
                    exif.pictureControl = name.isEmpty ? nil : name
                }
                exif.activeDLighting = notes[0x0022].flatMap { try? mn.int($0) }
            }
        }
        self.exif = exif
        self.makerNoteLittleEndian = makerNoteLittleEndian
        self.fileLittleEndian = tiff.littleEndian
        self.rawData = data
        self.nefCompression = nefCompression
        self.linearizationOffset = linearizationOffset
        self.blackLevel = blackLevel
        self.asShotRB = asShotRB.map { (r: $0.0, b: $0.1) }

        guard dataOffset > 0, dataOffset + dataLength <= data.count else {
            throw Failure.corrupt("RAW 本体の位置がファイルの外を指しています")
        }
    }

    /// 自前で読めない理由(読めるなら nil)
    var unsupportedReason: String? {
        guard make.uppercased().hasPrefix("NIKON") else { return "ニコンの NEF ではありません" }
        guard bitsPerSample == 12 || bitsPerSample == 14 else { return "\(bitsPerSample)bit の NEF には未対応" }
        if compression == 1 {
            // 非圧縮: 1 画素 16bit で並んでいる形だけ読む(12bit を詰めた形は未対応)
            guard dataLength >= width * height * 2 else { return "詰めて保存された非圧縮の NEF には未対応" }
            return nil
        }
        guard compression == 34713 else { return "この圧縮方式(\(compression))の NEF には未対応" }
        guard let v = compressionVersion else { return "展開に必要なメーカーノートの値(0x0096)がありません" }
        guard v.0 == 0x46 || (v.0 == 0x44 && v.1 == 0x20) else {
            return String(format: "この版の NEF 圧縮(0x%02X 0x%02X)には未対応", v.0, v.1)
        }
        return nil
    }

    /// メーカーノート 0x0096 の先頭 2 バイト(圧縮の版)。
    /// 0x46 = ロスレス、0x44 0x20 = 圧縮(値の変換カーブと、途中でハフマン表を替える行を持つ)
    var compressionVersion: (UInt8, UInt8)? {
        guard let m = linearizationOffset, m + 2 <= rawData.count else { return nil }
        return (rawData[rawData.startIndex + m], rawData[rawData.startIndex + m + 1])
    }

    // MARK: - 圧縮の展開

    /// ハフマン符号の表(dcraw / LibRaw の nikon_tree と同じ並び)。
    /// 先頭 16 バイトが「符号の長さ 1〜16 ビットの個数」、その後ろが値。
    /// 値の下位 4 ビット = 差分のビット数、上位 4 ビット = 省いた下位ビット数(圧縮のみ)
    private static let trees: [[UInt8]] = [
        [0, 1, 5, 1, 1, 1, 1, 1, 1, 2, 0, 0, 0, 0, 0, 0,  // 12bit 圧縮
         5, 4, 3, 6, 2, 7, 1, 0, 8, 9, 11, 10, 12],
        [0, 1, 5, 1, 1, 1, 1, 1, 1, 2, 0, 0, 0, 0, 0, 0,  // 12bit 圧縮(split 以降)
         0x39, 0x5a, 0x38, 0x27, 0x16, 5, 4, 3, 2, 1, 0, 11, 12, 12],
        [0, 1, 4, 2, 3, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0,  // 12bit ロスレス
         5, 4, 6, 3, 7, 2, 8, 1, 9, 0, 10, 11, 12],
        [0, 1, 4, 3, 1, 1, 1, 1, 1, 2, 0, 0, 0, 0, 0, 0,  // 14bit 圧縮
         5, 6, 4, 7, 8, 3, 9, 2, 1, 0, 10, 11, 12, 13, 14],
        [0, 1, 5, 1, 1, 1, 1, 1, 1, 1, 2, 0, 0, 0, 0, 0,  // 14bit 圧縮(split 以降)
         8, 0x5c, 0x4b, 0x3a, 0x29, 7, 6, 5, 4, 3, 2, 1, 0, 13, 14],
        [0, 1, 4, 2, 2, 3, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0,  // 14bit ロスレス
         7, 6, 8, 5, 9, 4, 10, 3, 11, 12, 2, 0, 1, 13, 14],
    ]

    /// 符号の先頭 maxBits ビットで引く表。値は (符号の長さ << 8 | 値)
    private static func lookupTable(_ tree: [UInt8]) -> (table: [UInt16], maxBits: Int) {
        let counts = Array(tree[0..<16])
        var maxBits = 16
        while maxBits > 0, counts[maxBits - 1] == 0 { maxBits -= 1 }
        var table = [UInt16](repeating: 0, count: 1 << maxBits)
        var symbol = 16, slot = 0
        for len in 1...maxBits {
            for _ in 0..<Int(counts[len - 1]) {
                let value = symbol < tree.count ? tree[symbol] : 0
                let entry = UInt16(len << 8) | UInt16(value)
                for _ in 0..<(1 << (maxBits - len)) where slot < table.count {
                    table[slot] = entry
                    slot += 1
                }
                symbol += 1
            }
        }
        return (table, maxBits)
    }

    /// RAW 本体を展開して、幅 × 高さの生の値(黒レベルを引く前)を返す。
    ///
    /// 各画素は「同じ色の左隣(行の先頭 2 画素は 2 行上の同じ色)」からの差分がハフマン符号で並んでいる
    /// (dcraw / LibRaw の nikon_load_raw と同じ手順を自前で書いたもの)。
    /// 圧縮(非可逆)では、展開した値を変換カーブに通したものが生の値になる。
    func decode() throws -> [UInt16] {
        if let reason = unsupportedReason { throw Failure.notNEF(reason) }
        if compression == 1 { return try decodeUncompressed() }
        guard let meta = linearizationOffset, let (ver0, ver1) = compressionVersion else {
            throw Failure.notNEF("未対応の NEF です")
        }
        let data = rawData
        // 0x0096 の中の 16bit の値(メーカーノートのバイト順)
        func get16(_ i: Int) throws -> Int {
            let p = meta + i
            guard p + 2 <= data.count else { throw Failure.corrupt("メーカーノートが途中で切れています") }
            let a = Int(data[data.startIndex + p]), b = Int(data[data.startIndex + p + 1])
            return makerNoteLittleEndian ? a | b << 8 : a << 8 | b
        }

        // 予測の初期値 2×2 [行の偶奇 * 2 + 列]
        let vpred: [UInt16] = try (0..<4).map { UInt16(try get16(2 + $0 * 2)) }
        // 値の変換カーブ(ロスレスはそのまま)
        var curve = [UInt16](unsafeUninitializedCapacity: 0x10000) { buf, n in
            for i in 0..<0x10000 { buf[i] = UInt16(i) }
            n = 0x10000
        }
        var maxValue = (1 << bitsPerSample) & 0x7FFF
        var split = 0
        var tree = ver0 == 0x46 ? 2 : 0
        if bitsPerSample == 14 { tree += 3 }
        if ver0 == 0x44, ver1 == 0x20 {
            // カーブは step 刻みの点で持っていて、間は直線で補う
            let csize = try get16(10)
            guard csize > 1 else { throw Failure.corrupt("変換カーブが読めません") }
            let step = maxValue / (csize - 1)
            guard step > 0, (csize - 1) * step < curve.count else { throw Failure.corrupt("変換カーブが読めません") }
            for i in 0..<csize { curve[i * step] = UInt16(try get16(12 + i * 2)) }
            for i in 0..<maxValue {
                let lo = i - i % step, t = i % step
                curve[i] = UInt16((Int(curve[lo]) * (step - t) + Int(curve[lo + step]) * t) / step)
            }
            split = try get16(562)
        }
        while maxValue > 2, curve[maxValue - 2] == curve[maxValue - 1] { maxValue -= 1 }

        let tables = (Self.lookupTable(Self.trees[tree]), split > 0 ? Self.lookupTable(Self.trees[tree + 1]) : nil)
        let w = width, h = height, start = dataOffset
        let end = min(data.count, dataOffset + dataLength)
        var out = [UInt16](repeating: 0, count: w * h)
        var corrupt = false

        // 速さのため、ループで書き換える値はすべてこの中の変数にする
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            curve.withUnsafeBufferPointer { curve in
                out.withUnsafeMutableBufferPointer { dst in
                    let src = raw.bindMemory(to: UInt8.self)
                    var pos = start
                    // 上位ビットから読むビットバッファ
                    var buffer: UInt64 = 0
                    var count = 0
                    var (table, maxBits) = tables.0
                    var vp = (vpred[0], vpred[1], vpred[2], vpred[3])
                    var hpred: (UInt16, UInt16) = (0, 0)
                    var minValue = 0, maxV = maxValue
                    var bad = false
                    for row in 0..<h {
                        if row == split, let next = tables.1 {
                            // ここから先は別のハフマン表(下位ビットを省いた符号が混ざる)
                            (table, maxBits) = next
                            minValue = 16
                            maxV += minValue << 1
                        }
                        let odd = row & 1 == 1
                        let rowOut = dst.baseAddress! + row * w
                        table.withUnsafeBufferPointer { table in
                            for col in 0..<w {
                                while count <= 56 {
                                    let byte: UInt64 = pos < end ? UInt64(src[pos]) : 0
                                    pos += 1
                                    buffer |= byte << UInt64(56 - count)
                                    count += 8
                                }
                                let entry = table[Int(buffer >> UInt64(64 - maxBits))]
                                let codeLength = Int(entry >> 8)
                                buffer <<= UInt64(codeLength)
                                count -= codeLength
                                let len = Int(entry & 15), shl = Int(entry >> 4 & 15)
                                // 差分: (len - shl) ビットの値を shl ビット左にずらす。先頭ビットが 0 なら負の数
                                var diff = 0
                                if len > 0 {
                                    let n = len - shl
                                    let bits = n > 0 ? Int(buffer >> UInt64(64 - n)) : 0
                                    buffer <<= UInt64(n)
                                    count -= n
                                    diff = (((bits << 1) + 1) << shl) >> 1
                                    if diff & (1 << (len - 1)) == 0 { diff -= (1 << len) - (shl == 0 ? 1 : 0) }
                                }
                                let d = UInt16(truncatingIfNeeded: diff)
                                let value: UInt16
                                switch (col, odd) {
                                case (0, false): vp.0 &+= d; value = vp.0; hpred.0 = value
                                case (1, false): vp.1 &+= d; value = vp.1; hpred.1 = value
                                case (0, true): vp.2 &+= d; value = vp.2; hpred.0 = value
                                case (1, true): vp.3 &+= d; value = vp.3; hpred.1 = value
                                default:
                                    if col & 1 == 0 {
                                        hpred.0 &+= d
                                        value = hpred.0
                                    } else {
                                        hpred.1 &+= d
                                        value = hpred.1
                                    }
                                }
                                if Int(value &+ UInt16(minValue)) >= maxV { bad = true }
                                let index = min(max(Int(Int16(bitPattern: value)), 0), 0x3FFF)
                                rowOut[col] = curve[index]
                            }
                        }
                    }
                    // データの終わりを超えて読み進んだ
                    if pos * 8 - count > end * 8 { bad = true }
                    corrupt = bad
                }
            }
        }
        if corrupt { throw Failure.corrupt("RAW データが壊れているか、展開の手順が合っていません") }
        return out
    }

    // MARK: - 非圧縮

    /// 非圧縮: 1 画素 16bit(ファイルのバイト順)で行ごとに並んでいる。値は下位 bitsPerSample ビット
    private func decodeUncompressed() throws -> [UInt16] {
        let w = width, h = height, start = dataOffset
        let maxValue = UInt16((1 << bitsPerSample) - 1)
        let little = fileLittleEndian
        var out = [UInt16](repeating: 0, count: w * h)
        var corrupt = false
        rawData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            out.withUnsafeMutableBufferPointer { dst in
                var bad = false
                for i in 0..<(w * h) {
                    let a = UInt16(raw[start + i * 2]), b = UInt16(raw[start + i * 2 + 1])
                    let v = little ? a | b << 8 : a << 8 | b
                    if v > maxValue { bad = true }
                    dst[i] = min(v, maxValue)
                }
                corrupt = bad
            }
        }
        if corrupt { throw Failure.corrupt("非圧縮の RAW データに、ビット数を超える値があります") }
        return out
    }
}
