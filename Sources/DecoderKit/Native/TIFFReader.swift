import Foundation

/// TIFF(と、それを土台にした NEF などの RAW)の IFD を読む最小限の自前実装。
/// ファイルはメモリにマップして読むだけで、書き換えない。
struct TIFFReader {
    let data: Data
    let littleEndian: Bool
    /// オフセットの基準位置。ファイル本体は 0、メーカーノートの中の TIFF はその先頭
    let base: Int

    enum Failure: Error { case notTIFF, outOfRange }

    /// ファイルの先頭の TIFF ヘッダー("II*\0" / "MM\0*")
    init(data: Data) throws {
        try self.init(data: data, headerAt: 0)
    }

    /// 任意の位置にある TIFF ヘッダーから読む(ニコンのメーカーノートは中に TIFF を持つ)
    init(data: Data, headerAt offset: Int) throws {
        self.data = data
        self.base = offset
        guard offset + 8 <= data.count else { throw Failure.notTIFF }
        let a = data[data.startIndex + offset], b = data[data.startIndex + offset + 1]
        switch (a, b) {
        case (0x49, 0x49): littleEndian = true
        case (0x4D, 0x4D): littleEndian = false
        default: throw Failure.notTIFF
        }
        guard (try? u16(at: offset + 2)) == 42 else { throw Failure.notTIFF }
    }

    /// 最初の IFD の位置(base からの相対)
    var firstIFDOffset: Int { (try? u32(at: base + 4)) ?? 0 }

    // MARK: - 数値の読み出し(位置はファイルの先頭からの絶対位置)

    func u8(at i: Int) throws -> Int {
        guard i >= 0, i < data.count else { throw Failure.outOfRange }
        return Int(data[data.startIndex + i])
    }

    func u16(at i: Int) throws -> Int {
        let a = try u8(at: i), b = try u8(at: i + 1)
        return littleEndian ? a | b << 8 : a << 8 | b
    }

    func u32(at i: Int) throws -> Int {
        let a = try u16(at: i), b = try u16(at: i + 2)
        return littleEndian ? a | b << 16 : a << 16 | b
    }

    // MARK: - IFD

    struct Entry {
        let tag: Int
        let type: Int
        let count: Int
        /// 値が置かれている位置(ファイルの先頭からの絶対位置)
        let valueOffset: Int

        /// 型ごとの 1 個あたりのバイト数
        var unitSize: Int {
            switch type {
            case 1, 2, 6, 7: 1
            case 3, 8: 2
            case 4, 9, 11, 13: 4
            case 5, 10, 12: 8
            default: 0
            }
        }
    }

    struct IFD {
        let entries: [Int: Entry]
        /// 次の IFD の位置(base からの相対。0 なら終わり)
        let next: Int

        subscript(tag: Int) -> Entry? { entries[tag] }
    }

    /// base からの相対位置 `offset` にある IFD を読む
    func ifd(at offset: Int) throws -> IFD {
        let start = base + offset
        let n = try u16(at: start)
        guard n > 0, n < 4096 else { throw Failure.outOfRange }
        var entries: [Int: Entry] = [:]
        for k in 0..<n {
            let e = start + 2 + k * 12
            let tag = try u16(at: e), type = try u16(at: e + 2), count = try u32(at: e + 4)
            var entry = Entry(tag: tag, type: type, count: count, valueOffset: e + 8)
            // 4 バイトに収まらない値は別の場所にある
            if entry.unitSize * count > 4 {
                entry = Entry(tag: tag, type: type, count: count, valueOffset: base + (try u32(at: e + 8)))
            }
            entries[tag] = entry
        }
        let next = try u32(at: start + 2 + n * 12)
        return IFD(entries: entries, next: next)
    }

    /// IFD0 から「次の IFD」をたどった一覧
    func chain() -> [IFD] {
        var list: [IFD] = []
        var offset = firstIFDOffset
        var seen = Set<Int>()
        while offset > 0, seen.insert(offset).inserted, list.count < 16, let d = try? ifd(at: offset) {
            list.append(d)
            offset = d.next
        }
        return list
    }

    // MARK: - 値の解釈

    /// 整数の値(BYTE / SHORT / LONG と符号付き)。i 番目
    func int(_ e: Entry, _ i: Int = 0) throws -> Int {
        guard i < e.count else { throw Failure.outOfRange }
        let p = e.valueOffset + i * e.unitSize
        switch e.type {
        case 1, 7: return try u8(at: p)
        case 6: return Int(Int8(truncatingIfNeeded: try u8(at: p)))
        case 3: return try u16(at: p)
        case 8: return Int(Int16(truncatingIfNeeded: try u16(at: p)))
        case 4, 13: return try u32(at: p)
        case 9: return Int(Int32(truncatingIfNeeded: try u32(at: p)))
        default: return Int(try real(e, i))
        }
    }

    /// 実数の値(RATIONAL なども含む)。i 番目
    func real(_ e: Entry, _ i: Int = 0) throws -> Double {
        guard i < e.count else { throw Failure.outOfRange }
        let p = e.valueOffset + i * e.unitSize
        switch e.type {
        case 5, 10:
            var num = try u32(at: p), den = try u32(at: p + 4)
            if e.type == 10 {
                num = Int(Int32(truncatingIfNeeded: num))
                den = Int(Int32(truncatingIfNeeded: den))
            }
            return den == 0 ? 0 : Double(num) / Double(den)
        case 11: return Double(Float(bitPattern: UInt32(try u32(at: p))))
        case 12:
            let hi = UInt64(try u32(at: p + (littleEndian ? 4 : 0)))
            let lo = UInt64(try u32(at: p + (littleEndian ? 0 : 4)))
            return Double(bitPattern: hi << 32 | lo)
        default: return Double(try int(e, i))
        }
    }

    func ints(_ e: Entry) -> [Int] {
        (0..<min(e.count, 4096)).compactMap { try? int(e, $0) }
    }

    /// ASCII の値(末尾の NUL と空白を落とす)
    func string(_ e: Entry) -> String {
        guard let d = bytes(e) else { return "" }
        return String(decoding: d.prefix { $0 != 0 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
    }

    /// 値のバイト列そのまま
    func bytes(_ e: Entry) -> Data? {
        let n = e.count * e.unitSize
        guard e.valueOffset >= 0, e.valueOffset + n <= data.count else { return nil }
        let s = data.startIndex + e.valueOffset
        return data.subdata(in: s..<s + n)
    }
}
