import CryptoKit
import DecoderKit
import Foundation

extension Catalog {
    /// ファイルの指紋: サイズ + 先頭 1MB の SHA-256
    public static func fingerprint(of url: URL) throws -> (size: Int64, fingerprint: String) {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 1 << 20) ?? Data()
        let hash = SHA256.hash(data: head).prefix(16).map { String(format: "%02x", $0) }.joined()
        return (size, "\(size)-\(hash)")
    }

    /// すべての登録フォルダをスキャン
    public func scanAll() throws -> ScanResult {
        var total = ScanResult()
        for folder in try folders() {
            let r = try scan(folderID: folder.id)
            total.total += r.total
            total.added += r.added
            total.relinked += r.relinked
            total.missing += r.missing
            total.sidecarsImported += r.sidecarsImported
            total.folderUnavailable = total.folderUnavailable || r.folderUnavailable
        }
        return total
    }

    /// 登録フォルダの中(サブフォルダ含む)を調べてカタログを更新する。
    /// - 新しい RAW は追加(初回は旧方式のサイドカーがあれば取り込む)
    /// - パスが変わった RAW は指紋で照合してつなぎ直す(現像データを引き継ぐ)
    /// - 見つからない RAW は「見つからない」印を付ける(現像データは消さない)
    public func scan(folderID: Int64) throws -> ScanResult {
        guard let folder = try folders().first(where: { $0.id == folderID }) else { return ScanResult() }
        var result = ScanResult()
        guard folder.isAvailable else {
            result.folderUnavailable = true
            return result
        }

        let files = Self.rawFiles(in: folder.url)
        result.total = files.count
        let known = Dictionary(uniqueKeysWithValues: try photos(folderID: folderID).map { ($0.path, $0) })
        let filePaths = Set(files.map(\.path))

        for file in files {
            if let photo = known[file.path] {
                if photo.isMissing { try setMissing(photo.id, false) }
                continue
            }
            // 他のフォルダにすでに登録済み(フォルダの入れ子登録など)
            if try photo(path: file.path) != nil { continue }

            let (size, fp) = try Self.fingerprint(of: file)
            // 移動・改名された写真を探す(元のパスにもう無いもの)
            if let moved = try photos(fingerprint: fp).first(where: {
                !FileManager.default.fileExists(atPath: $0.path)
            }) {
                try relink(moved.id, to: file, folderID: folderID)
                result.relinked += 1
                continue
            }
            let imported = try insertPhoto(file, folderID: folderID, size: size, fingerprint: fp)
            result.added += 1
            if imported { result.sidecarsImported += 1 }
        }

        for photo in known.values where !filePaths.contains(photo.path) {
            // 別フォルダへ移ってつなぎ直されたものは除く
            if try self.photo(id: photo.id)?.path != photo.path { continue }
            if !photo.isMissing { try setMissing(photo.id, true) }
            result.missing += 1
        }
        return result
    }

    static func rawFiles(in folder: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var urls: [URL] = []
        for case let url as URL in e where RawFiles.extensions.contains(url.pathExtension.lowercased()) {
            urls.append(url.standardizedFileURL.resolvingSymlinksInPath())
        }
        return urls.sorted { $0.path < $1.path }
    }

    /// 戻り値: 旧サイドカーを取り込んだか
    private func insertPhoto(_ url: URL, folderID: Int64, size: Int64, fingerprint: String) throws -> Bool {
        let meta = try? DecoderRegistry.metadata(url)
        return try locked {
            try db.transaction {
                try db.run("""
                    INSERT INTO photos (folder_id, path, file_size, fingerprint, capture_date, metadata, added_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, [.int(folderID), .text(url.path), .int(size), .text(fingerprint),
                          meta?.captureDate.sql ?? .null, meta.map { .text(Self.json($0)) } ?? .null,
                          .double(Date().timeIntervalSince1970)])
                let photoID = db.lastInsertID
                // 以前の方式(RAW の隣の .rawlab.json)があれば最初のバージョンとして取り込む。ファイルは消さない
                if let sidecar = Sidecar.load(for: url) {
                    try createVersion(photoID: photoID, name: "現像 1", decoderID: sidecar.decoderID,
                                      decodeOptions: sidecar.decodeOptions, settings: sidecar.settings)
                    return true
                }
                try createVersion(photoID: photoID, name: "現像 1")
                return false
            }
        }
    }

    private func relink(_ photoID: Int64, to url: URL, folderID: Int64) throws {
        try locked {
            _ = try db.run("UPDATE photos SET path = ?, folder_id = ?, missing = 0 WHERE id = ?",
                           [.text(url.path), .int(folderID), .int(photoID)])
        }
    }

    private func setMissing(_ photoID: Int64, _ missing: Bool) throws {
        try locked {
            _ = try db.run("UPDATE photos SET missing = ? WHERE id = ?", [.int(missing ? 1 : 0), .int(photoID)])
        }
    }
}
