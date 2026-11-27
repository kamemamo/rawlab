import Foundation

/// DNG の本体の画像が JPEG XL で圧縮されているか(DNG 1.7。iPhone 16 Pro などの ProRAW)を見分ける。
///
/// LibRaw(Homebrew 版は Adobe DNG SDK なし)と rawler 0.8 は JPEG XL を読めないので、
/// 開く前に見分けて「非対応」と表示する。Core Image(macOS)は読める。
public enum DNGCompression {
    /// TIFF の Compression タグで JPEG XL を表す値(DNG 1.7)
    static let jpegXL = 52546

    /// 非対応のデコーダーで出す説明
    public static let jpegXLReason = "JPEG XL 圧縮の DNG(iPhone ProRAW など)には非対応"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [URL: Bool] = [:]

    /// 本体の画像(SubfileType = 0 の IFD)が JPEG XL なら true。DNG 以外は読まずに false
    public static func isJPEGXL(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "dng" else { return false }
        lock.lock()
        if let hit = cache[url] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let result = (try? scan(url)) ?? false
        lock.lock()
        cache[url] = result
        lock.unlock()
        return result
    }

    /// IFD0 から順に、SubIFD もたどって本体の画像の圧縮方式を調べる
    private static func scan(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count) ?? Data()
        }

        let header = try read(0, 8)
        guard header.count == 8 else { return false }
        let little: Bool
        switch (header[0], header[1]) {
        case (0x49, 0x49): little = true   // "II"
        case (0x4D, 0x4D): little = false  // "MM"
        default: return false
        }
        func u16(_ d: Data, _ i: Int) -> Int {
            let a = Int(d[d.startIndex + i]), b = Int(d[d.startIndex + i + 1])
            return little ? a | b << 8 : a << 8 | b
        }
        func u32(_ d: Data, _ i: Int) -> Int {
            little ? u16(d, i) | u16(d, i + 2) << 16 : u16(d, i) << 16 | u16(d, i + 2)
        }

        var queue = [u32(header, 4)]
        var visited = Set<Int>()
        while let offset = queue.first, visited.count < 32 {
            queue.removeFirst()
            guard offset > 0, visited.insert(offset).inserted else { continue }
            let countData = try read(UInt64(offset), 2)
            guard countData.count == 2 else { continue }
            let n = u16(countData, 0)
            guard n > 0, n < 1000 else { continue }
            let entries = try read(UInt64(offset + 2), n * 12 + 4)
            guard entries.count == n * 12 + 4 else { continue }

            var subfileType = -1, compression = -1
            for i in 0..<n {
                let e = i * 12
                let tag = u16(entries, e), type = u16(entries, e + 2), count = u32(entries, e + 4)
                // SHORT か LONG で 1 個の値
                let value = type == 3 ? u16(entries, e + 8) : u32(entries, e + 8)
                switch tag {
                case 254: subfileType = value
                case 259: compression = value
                case 330:  // SubIFDs
                    if count == 1 {
                        queue.append(u32(entries, e + 8))
                    } else if count > 1, count < 64 {
                        let list = try read(UInt64(u32(entries, e + 8)), count * 4)
                        if list.count == count * 4 {
                            queue += (0..<count).map { u32(list, $0 * 4) }
                        }
                    }
                default: break
                }
            }
            if subfileType == 0 { return compression == jpegXL }
            queue.append(u32(entries, n * 12))  // 次の IFD
        }
        return false
    }
}
