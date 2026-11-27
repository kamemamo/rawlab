import Foundation

/// オリンパス(OM デジタル)の ORF を自前で読む。
///
/// ORF は TIFF とほぼ同じ形で、ヘッダーの 42 の代わりに "RO" が入っている。
/// RAW 本体は IFD0 のストリップにあり、オリンパス独自の方式で圧縮されている
/// (dcraw / LibRaw の olympus_load_raw と同じ考え方)。
/// WB と黒レベルはメーカーノートの ImageProcessing(0x2040)の中にある。
///
/// - 対応: 12bit の圧縮 ORF
/// - 未対応: 非圧縮の ORF、14bit の ORF(OM-1 など。展開の方式が違う)
struct OlympusORF {
    let make: String
    let model: String
    let orientation: Int
    let width: Int
    let height: Int
    let dataOffset: Int
    let dataLength: Int
    /// ImageProcessing 0x0600 の黒レベル(R, G, G, B の順)
    let blackLevel: [Int]?
    /// ImageProcessing 0x0100 の WB 係数(R, B。緑 = 1)
    let asShotRB: (r: Double, b: Double)?
    /// Equipment 0x0201 の 1 バイト目(レンズの種類)など、表示用の値
    var exif: RawExif
    let rawData: Data

    /// 12bit の RAW の最大値
    let white = 4095

    enum Failure: LocalizedError {
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let m): "ORF を展開できません: \(m)"
            }
        }
    }

    init(data: Data) throws {
        guard let tiff = try? TIFFReader(data: data),
              let magic = try? tiff.u16(at: 2), magic != 42
        else { throw Failure.invalid("ORF の形式ではありません") }
        guard let ifd0 = tiff.chain().first else { throw Failure.invalid("IFD が読めません") }
        func int(_ tag: Int) -> Int? { ifd0[tag].flatMap { try? tiff.int($0) } }

        make = ifd0[271].map(tiff.string) ?? ""
        model = ifd0[272].map(tiff.string) ?? ""
        orientation = int(274) ?? 1
        width = int(256) ?? 0
        height = int(257) ?? 0
        dataOffset = int(273) ?? 0
        dataLength = ifd0[279].map { tiff.ints($0).reduce(0, +) } ?? 0
        rawData = data

        var exif = RawExif()
        var blackLevel: [Int]?
        var asShotRB: (Double, Double)?
        if let p = ifd0[34665], let exifIFD = try? tiff.ifd(at: tiff.int(p)) {
            exif.readBasics(tiff, exifIFD)
            // メーカーノート: "OLYMPUS\0" + "II"(バイト順)+ 版 2 バイト のあとに IFD。
            // 中のオフセットはメーカーノートの先頭から数える
            if let note = exifIFD[37500],
               let head = tiff.bytes(TIFFReader.Entry(tag: 0, type: 7, count: 10, valueOffset: note.valueOffset)),
               head.prefix(8) == Data("OLYMPUS\0".utf8) {
                let mn = TIFFReader(data: data, base: note.valueOffset,
                                    littleEndian: head[head.startIndex + 8] == 0x49)
                if let notes = try? mn.ifd(at: 12) {
                    func sub(_ tag: Int) -> TIFFReader.IFD? {
                        notes[tag].flatMap { try? mn.int($0) }.flatMap { try? mn.ifd(at: $0) }
                    }
                    if let ip = sub(0x2040) {
                        if let e = ip[0x0100], e.count >= 2,
                           let r = try? mn.int(e, 0), let b = try? mn.int(e, 1), r > 0, b > 0 {
                            asShotRB = (Double(r) / 256, Double(b) / 256)
                        }
                        if let e = ip[0x0600], e.count == 4 { blackLevel = mn.ints(e) }
                    }
                    if exif.lensModel?.isEmpty ?? true, let eq = sub(0x2010), let e = eq[0x0203] {
                        exif.lensModel = mn.string(e)
                    }
                }
            }
        }
        self.exif = exif
        self.blackLevel = blackLevel
        self.asShotRB = asShotRB
    }

    /// 自前で読めない理由(読めるなら nil)
    var unsupportedReason: String? {
        guard width > 0, height > 0, dataOffset > 0, dataOffset + dataLength <= rawData.count else {
            return "画像データの位置が読めない ORF には未対応"
        }
        if dataLength >= width * height * 3 / 2 { return "非圧縮の ORF には未対応" }
        return nil
    }

    /// 圧縮を解いた RAW の値(width × height、12bit)。
    ///
    /// 同じ色の画素(2 つ左・2 つ上)から予測し、その差を「符号 + 下位 2 ビット + 上位(先頭の 0 の数)+ 残り」
    /// の形で読む。残りのビット数は、同じ列の偶奇の直前の値の大きさから決まる(適応的)
    func decode() throws -> [UInt16] {
        if let reason = unsupportedReason { throw Failure.invalid(reason) }
        let w = width, h = height
        var out = [UInt16](repeating: 0, count: w * h)
        var bad = false
        rawData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var reader = BitReader(bytes: bytes.baseAddress!, pos: dataOffset + 7,  // 先頭の 7 バイトは読み飛ばす
                                   end: dataOffset + dataLength)
            out.withUnsafeMutableBufferPointer { out in
                let dst = out.baseAddress!
                for row in 0..<h {
                    // 列の偶奇ごとに [直前の値, 平均の目安, 小さい値が続いた数]
                    var even = (0, 0, 0), odd = (0, 0, 0)
                    for col in 0..<w {
                        var (c0, c1, c2) = col & 1 == 0 ? even : odd
                        let i = c2 < 3 ? 2 : 0
                        var nbits = 2 + i
                        while (c0 & 0xFFFF) >> (nbits + i) != 0 { nbits += 1 }
                        let head = reader.bits(3)
                        let low = head & 3
                        let sign = head & 4 != 0 ? -1 : 0
                        // 上位: 12 ビットのうちの先頭の 0 の数(全部 0 なら 12)
                        let peek = reader.peek12()
                        var high = peek == 0 ? 12 : peek.leadingZeroBitCount - (Int.bitWidth - 12)
                        let used = high == 12 ? 12 : high + 1
                        reader.skip(used)
                        if high == 12 { high = reader.bits(16 - nbits) >> 1 }
                        c0 = (high << nbits) | reader.bits(nbits)
                        let diff = (c0 ^ sign) + c1
                        c1 = (diff * 3 + c1) >> 5
                        c2 = c0 > 16 ? 0 : c2 + 1
                        if col & 1 == 0 { even = (c0, c1, c2) } else { odd = (c0, c1, c2) }

                        let pred: Int
                        if row < 2, col < 2 {
                            pred = 0
                        } else if row < 2 {
                            pred = Int(dst[row * w + col - 2])
                        } else if col < 2 {
                            pred = Int(dst[(row - 2) * w + col])
                        } else {
                            let left = Int(dst[row * w + col - 2])
                            let up = Int(dst[(row - 2) * w + col])
                            let upLeft = Int(dst[(row - 2) * w + col - 2])
                            if (left < upLeft && upLeft < up) || (up < upLeft && upLeft < left) {
                                pred = abs(left - upLeft) > 32 || abs(up - upLeft) > 32
                                    ? left + up - upLeft
                                    : (left + up) >> 1
                            } else {
                                pred = abs(left - upLeft) > abs(up - upLeft) ? left : up
                            }
                        }
                        let value = pred + ((diff << 2) | low)
                        if value >> 12 != 0 { bad = true }
                        dst[row * w + col] = UInt16(truncatingIfNeeded: value)
                    }
                }
            }
        }
        if bad { throw Failure.invalid("値が範囲を超えました(データが壊れている可能性)") }
        return out
    }

    /// 上位ビットから読むビット列(マーカーや FF の詰め物はない)
    private struct BitReader {
        let bytes: UnsafePointer<UInt8>
        var pos: Int
        let end: Int
        var buffer: UInt64 = 0
        var count = 0

        init(bytes: UnsafePointer<UInt8>, pos: Int, end: Int) {
            self.bytes = bytes
            self.pos = pos
            self.end = end
        }

        @inline(__always) mutating func fill() {
            while count <= 56 {
                let b: UInt64 = pos < end ? UInt64(bytes[pos]) : 0
                pos += 1
                buffer |= b << UInt64(56 - count)
                count += 8
            }
        }

        @inline(__always) mutating func bits(_ n: Int) -> Int {
            guard n > 0 else { return 0 }
            fill()
            let v = Int(buffer >> UInt64(64 - n))
            buffer <<= UInt64(n)
            count -= n
            return v
        }

        @inline(__always) mutating func peek12() -> Int {
            fill()
            return Int(buffer >> 52)
        }

        @inline(__always) mutating func skip(_ n: Int) {
            buffer <<= UInt64(n)
            count -= n
        }
    }
}
