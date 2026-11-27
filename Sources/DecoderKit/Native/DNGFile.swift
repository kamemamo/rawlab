import Foundation
import ImageIO

/// DNG を自前で読む。
/// DNG は TIFF に RAW 用のタグを足した公開の形式で、黒・白レベル、撮影時の WB、色の行列が
/// ファイルの中に入っている。そのため機種ごとの表がなくても読める。
///
/// - 対応: ベイヤー配列(2×2)の CFA と、デモザイク済みの RGB(LinearRaw。iPhone の ProRAW など)
/// - 圧縮: 非圧縮(8・16bit と、詰めた 10〜14bit)、ロスレス JPEG、JPEG XL(DNG 1.7)。
///   JPEG XL の展開だけは macOS の ImageIO に任せる(タイルごとに元のビット数の値のまま取り出す)
/// - ストリップとタイル、LinearizationTable、BlackLevel の繰り返し
/// - 未対応: 非可逆 JPEG・Deflate 圧縮、浮動小数、2×2 以外の配列、BlackLevelDeltaH/V。
///   理由は `unsupportedReason` で返す
/// - 色は D65 光源の ColorMatrix を使う(NEF の ColorMatrix2 と同じ扱い。2 つの行列の混ぜ合わせはしない)
struct DNGFile {
    let make: String
    let model: String
    let orientation: Int
    /// RAW 本体の大きさ(使わない縁も含む)
    let rawWidth: Int
    let rawHeight: Int
    let bitsPerSample: Int
    let compression: Int
    let photometric: Int
    let samplesPerPixel: Int
    let sampleFormat: Int
    /// 2×2 の色配置 [左上, 右上, 左下, 右下](ActiveArea の左上が基準)。0=R 1=G 2=B
    let cfa: [Int]?
    /// 使う範囲(上, 左, 下, 右)
    let activeArea: (top: Int, left: Int, bottom: Int, right: Int)
    /// 黒レベルの繰り返し(ActiveArea の左上が基準)
    let black: (rows: Int, cols: Int, values: [Double])
    let hasBlackDeltas: Bool
    let whiteLevel: Int
    let linearization: [UInt16]?
    /// 撮影時の白(カメラの RGB での白の値。緑 = 1 に近い)
    let asShotNeutral: [Double]?
    /// 明るさの基準の補正(EV)。ProRAW は白飛びを避けるため暗めに記録し、ここに +3.5 EV ほどを書く
    let baselineExposure: Double
    /// XYZ → カメラ(D65 のもの。なければもう一方)
    let colorMatrix: [Double]?
    let exif: RawExif
    let littleEndian: Bool
    let rawData: Data
    /// データの塊(ストリップかタイル)。x, y は RAW 本体の中の位置、w, h は塊の大きさ
    let pieces: [(x: Int, y: Int, w: Int, h: Int, offset: Int, length: Int)]

    enum Failure: LocalizedError {
        case notDNG(String)

        var errorDescription: String? {
            switch self {
            case .notDNG(let m): m
            }
        }
    }

    init(data: Data) throws {
        let tiff: TIFFReader
        do { tiff = try TIFFReader(data: data) } catch { throw Failure.notDNG("TIFF 形式ではありません") }
        let chain = tiff.chain()
        guard let ifd0 = chain.first else { throw Failure.notDNG("IFD が読めません") }
        guard ifd0[50706] != nil else { throw Failure.notDNG("DNG ではありません(DNGVersion がない)") }

        func int(_ d: TIFFReader.IFD, _ tag: Int, _ i: Int = 0) -> Int? { d[tag].flatMap { try? tiff.int($0, i) } }
        func reals(_ d: TIFFReader.IFD, _ tag: Int) -> [Double]? {
            d[tag].map { e in (0..<min(e.count, 4096)).compactMap { try? tiff.real(e, $0) } }
        }

        make = ifd0[271].map(tiff.string) ?? ""
        model = (ifd0[50708] ?? ifd0[272]).map(tiff.string) ?? ""
        orientation = int(ifd0, 274) ?? 1
        littleEndian = tiff.littleEndian
        rawData = data

        // 本体の IFD: NewSubfileType = 0 のもの(IFD0・SubIFD・後ろに続く IFD から)
        var candidates = chain
        for d in chain {
            if let sub = d[330] { candidates += tiff.ints(sub).compactMap { try? tiff.ifd(at: $0) } }
        }
        let mains = candidates.filter { (int($0, 254) ?? 0) == 0 }
        guard let raw = mains.first(where: { int($0, 262) == 32803 }) ?? mains.first else {
            throw Failure.notDNG("本体の画像が見つかりません")
        }

        rawWidth = int(raw, 256) ?? 0
        rawHeight = int(raw, 257) ?? 0
        bitsPerSample = int(raw, 258) ?? 0
        compression = int(raw, 259) ?? 1
        photometric = int(raw, 262) ?? 0
        samplesPerPixel = int(raw, 277) ?? 1
        sampleFormat = int(raw, 339) ?? 1

        // CFA の色配置。CFAPattern の値は CFAPlaneColor の番号
        let planes = raw[50710].map(tiff.ints) ?? [0, 1, 2]
        let dim = raw[33421].map(tiff.ints) ?? []
        let pattern = raw[33422].map(tiff.ints) ?? []
        if dim == [2, 2], pattern.count == 4, pattern.allSatisfy({ $0 < planes.count }),
           int(raw, 50711) ?? 1 == 1 {
            cfa = pattern.map { planes[$0] }
        } else {
            cfa = nil
        }

        let area = raw[50829].map(tiff.ints) ?? []
        activeArea = area.count == 4
            ? (area[0], area[1], area[2], area[3])
            : (0, 0, rawHeight, rawWidth)

        let repeatDim = raw[50713].map(tiff.ints) ?? [1, 1]
        let blackValues = reals(raw, 50714) ?? [0]
        if repeatDim.count == 2, repeatDim[0] * repeatDim[1] * samplesPerPixel == blackValues.count {
            black = (repeatDim[0], repeatDim[1], blackValues)
        } else {
            black = (1, 1, [blackValues.first ?? 0])
        }
        hasBlackDeltas = [50715, 50716].contains { (reals(raw, $0) ?? []).contains { $0 != 0 } }
        whiteLevel = int(raw, 50717) ?? ((1 << bitsPerSample) - 1)
        linearization = raw[50712].map { tiff.ints($0).map { UInt16(clamping: $0) } }

        baselineExposure = reals(ifd0, 50730)?.first ?? 0
        asShotNeutral = reals(ifd0, 50728).flatMap { $0.count == 3 && $0.allSatisfy { $0 > 0 } ? $0 : nil }
        // 色の行列: 光源が D65(21)のものを使う。なければ ColorMatrix2、それもなければ 1
        let m1 = reals(ifd0, 50721), m2 = reals(ifd0, 50722)
        let i1 = int(ifd0, 50778), i2 = int(ifd0, 50779)
        let chosen = i2 == 21 ? m2 : (i1 == 21 ? m1 : (m2 ?? m1))
        colorMatrix = chosen?.count == 9 ? chosen : nil

        var exif = RawExif()
        if let p = ifd0[34665], let e = try? tiff.ifd(at: tiff.int(p)) { exif.readBasics(tiff, e) }
        // 本体の IFD に EXIF の値が直接入っている DNG もある
        if exif.iso == 0 { exif.iso = raw[34855].flatMap { try? tiff.real($0) } ?? ifd0[34855].flatMap { try? tiff.real($0) } ?? 0 }
        self.exif = exif

        // データの塊: タイル(322〜325)かストリップ(273, 278, 279)
        var pieces: [(Int, Int, Int, Int, Int, Int)] = []
        if let tw = int(raw, 322), let th = int(raw, 323), tw > 0, th > 0,
           let offsets = raw[324].map(tiff.ints), let lengths = raw[325].map(tiff.ints) {
            let across = (rawWidth + tw - 1) / tw
            for (k, (o, l)) in zip(offsets, lengths).enumerated() {
                pieces.append(((k % across) * tw, (k / across) * th, tw, th, o, l))
            }
        } else if let offsets = raw[273].map(tiff.ints), let lengths = raw[279].map(tiff.ints) {
            let rows = int(raw, 278) ?? rawHeight
            for (k, (o, l)) in zip(offsets, lengths).enumerated() {
                pieces.append((0, k * rows, rawWidth, min(rows, rawHeight - k * rows), o, l))
            }
        }
        self.pieces = pieces.map { (x: $0.0, y: $0.1, w: $0.2, h: $0.3, offset: $0.4, length: $0.5) }
    }

    /// 自前で読めない理由(読めるなら nil)
    var unsupportedReason: String? {
        if isLinearRaw {
            guard samplesPerPixel == 3 else { return "RGB 以外のデモザイク済み DNG には未対応" }
        } else {
            guard photometric == 32803 else { return "CFA の画像を持たない DNG には未対応" }
            guard cfa != nil else { return "2×2 のベイヤー配列でない DNG には未対応" }
            let colors = cfa ?? []
            guard colors.filter({ $0 == 0 }).count == 1, colors.filter({ $0 == 2 }).count == 1,
                  colors.allSatisfy({ (0...2).contains($0) })
            else { return "RGB のベイヤー配列でない DNG には未対応" }
            guard samplesPerPixel == 1 else { return "1 画素に複数の値を持つ CFA の DNG には未対応" }
        }
        guard sampleFormat == 1 else { return "浮動小数などの DNG には未対応" }
        guard (8...16).contains(bitsPerSample) else { return "\(bitsPerSample)bit の DNG には未対応" }
        switch compression {
        case 1, 7, DNGCompression.jpegXL: break
        case 34892: return "非可逆 JPEG 圧縮の DNG には未対応"
        case 8: return "Deflate 圧縮の DNG には未対応"
        default: return "この圧縮方式(\(compression))の DNG には未対応"
        }
        if hasBlackDeltas { return "行・列ごとの黒レベル(BlackLevelDeltaH/V)を持つ DNG には未対応" }
        guard colorMatrix != nil else { return "色の行列(ColorMatrix)がない DNG には未対応" }
        guard !pieces.isEmpty, rawWidth > 0, rawHeight > 0,
              pieces.allSatisfy({ $0.offset >= 0 && $0.offset + $0.length <= rawData.count })
        else { return "画像データの位置が読めない DNG には未対応" }
        let a = activeArea
        guard a.top >= 0, a.left >= 0, a.bottom <= rawHeight, a.right <= rawWidth,
              a.bottom - a.top >= 2, a.right - a.left >= 2
        else { return "ActiveArea が画像の外を指している DNG には未対応" }
        return nil
    }

    /// デモザイク済みの RGB(LinearRaw)か
    var isLinearRaw: Bool { photometric == 34892 }

    // MARK: - 展開

    /// RAW 本体全体(使わない縁も含む)の値。LinearizationTable があれば通したあと。
    /// 1 画素に samplesPerPixel 個の値が並ぶ(CFA なら 1 個、LinearRaw なら R, G, B)
    func decode() throws -> [UInt16] {
        if let reason = unsupportedReason { throw Failure.notDNG(reason) }
        let w = rawWidth, h = rawHeight, spp = samplesPerPixel
        var out = [UInt16](repeating: 0, count: w * h * spp)
        try rawData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            try out.withUnsafeMutableBufferPointer { dst in
                if compression == DNGCompression.jpegXL {
                    try decodeJPEGXL(into: dst)
                    return
                }
                for p in pieces where p.x < w && p.y < h {
                    let width = min(p.w, w - p.x), height = min(p.h, h - p.y)
                    if compression == 7 {
                        // 成分は交互に並ぶので、値の数で数えれば CFA と同じに扱える
                        try LosslessJPEG.decode(bytes, start: p.offset, end: p.offset + p.length,
                                                into: dst, stride: w * spp, x0: p.x * spp, y0: p.y,
                                                width: width * spp, height: height, wrap: p.w * spp)
                    } else {
                        try unpack(bytes, p, into: dst, stride: w * spp, width: width, height: height)
                    }
                }
            }
        }
        if let table = linearization, !table.isEmpty {
            let last = table.count - 1
            for i in out.indices { out[i] = table[min(Int(out[i]), last)] }
        }
        return out
    }

    /// 非圧縮: 8・16bit はそのまま(16bit はファイルのバイト順)、それ以外は上位ビットから詰めて並ぶ。
    /// 各行はバイトの境目から始まる
    private func unpack(_ bytes: UnsafeBufferPointer<UInt8>,
                        _ p: (x: Int, y: Int, w: Int, h: Int, offset: Int, length: Int),
                        into dst: UnsafeMutableBufferPointer<UInt16>, stride: Int,
                        width: Int, height: Int) throws {
        let bps = bitsPerSample, spp = samplesPerPixel
        let width = width * spp
        let rowBytes = (p.w * spp * bps + 7) / 8
        guard rowBytes * height <= p.length else { throw Failure.notDNG("非圧縮のデータが足りません") }
        for row in 0..<height {
            let base = p.offset + row * rowBytes
            let o = (p.y + row) * stride + p.x * spp
            switch bps {
            case 8:
                for x in 0..<width { dst[o + x] = UInt16(bytes[base + x]) }
            case 16:
                for x in 0..<width {
                    let a = UInt16(bytes[base + x * 2]), b = UInt16(bytes[base + x * 2 + 1])
                    dst[o + x] = littleEndian ? a | b << 8 : a << 8 | b
                }
            default:
                var buffer: UInt64 = 0, count = 0, pos = base
                for x in 0..<width {
                    while count < bps {
                        buffer = buffer << 8 | UInt64(bytes[pos])
                        pos += 1
                        count += 8
                    }
                    count -= bps
                    dst[o + x] = UInt16(truncatingIfNeeded: buffer >> UInt64(count)) & UInt16((1 << bps) - 1)
                }
            }
        }
    }

    /// JPEG XL のタイルを ImageIO で展開する。ImageIO は 16bit の整数で返すが、
    /// 値は元のビット数のまま(10bit なら 0〜1023。非可逆なので少しはみ出すことがある)
    private func decodeJPEGXL(into dst: UnsafeMutableBufferPointer<UInt16>) throws {
        let w = rawWidth, h = rawHeight, spp = samplesPerPixel
        let maxValue = (1 << bitsPerSample) - 1
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        var failure: String?
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: pieces.count) { k in
            let p = pieces[k]
            guard p.x < w, p.y < h else { return }
            let tile = rawData.subdata(in: p.offset..<(p.offset + p.length))
            guard let source = CGImageSourceCreateWithData(tile as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, options),
                  let pixels = image.dataProvider?.data as Data?
            else {
                lock.lock(); failure = "JPEG XL のタイルを展開できません"; lock.unlock()
                return
            }
            let bpc = image.bitsPerComponent
            let channels = image.bitsPerPixel / bpc
            let little = image.bitmapInfo.contains(.byteOrder16Little)
                || (!image.bitmapInfo.contains(.byteOrder16Big) && CFByteOrderGetCurrent() == CFByteOrder(CFByteOrderLittleEndian.rawValue))
            guard bpc == 8 || bpc == 16, channels >= spp else {
                lock.lock(); failure = "JPEG XL のタイルの形が想定外です(\(bpc)bit・\(channels) 成分)"; lock.unlock()
                return
            }
            let width = min(p.w, w - p.x, image.width), height = min(p.h, h - p.y, image.height)
            let rowBytes = image.bytesPerRow
            pixels.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                let b = src.bindMemory(to: UInt8.self)
                for y in 0..<height {
                    let row = y * rowBytes
                    let o = ((p.y + y) * w + p.x) * spp
                    for x in 0..<width {
                        for c in 0..<spp {
                            let v: Int
                            if bpc == 16 {
                                let i = row + (x * channels + c) * 2
                                v = little ? Int(b[i]) | Int(b[i + 1]) << 8 : Int(b[i]) << 8 | Int(b[i + 1])
                            } else {
                                v = Int(b[row + x * channels + c])
                            }
                            dst[o + x * spp + c] = UInt16(min(v, maxValue))
                        }
                    }
                }
            }
        }
        if let failure { throw Failure.notDNG(failure) }
    }
}
