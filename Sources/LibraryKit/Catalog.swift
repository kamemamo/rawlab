import DecoderKit
import Foundation

/// RawLab ライブラリ(~/Pictures/RawLab Library/catalog.sqlite)。
/// RAW の場所・現像バージョン・書き出し履歴を管理する。RAW ファイル自体には一切書き込まない。
public final class Catalog: @unchecked Sendable {
    public let libraryURL: URL
    let db: SQLiteDB
    let lock = NSRecursiveLock()

    public static let defaultDecoderID = "libraw"

    /// 環境変数 RAWLAB_LIBRARY で差し替え可能(テスト用)
    public static var defaultLibraryURL: URL {
        if let override = ProcessInfo.processInfo.environment["RAWLAB_LIBRARY"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/RawLab Library")
    }

    public static var defaultExportRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/RawLab Export")
    }

    public init(libraryURL: URL = Catalog.defaultLibraryURL) throws {
        self.libraryURL = libraryURL
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        db = try SQLiteDB(path: libraryURL.appendingPathComponent("catalog.sqlite").path)
        try migrate()
    }

    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func migrate() throws {
        try db.exec("""
        PRAGMA journal_mode = WAL;
        PRAGMA foreign_keys = ON;
        CREATE TABLE IF NOT EXISTS folders (
            id INTEGER PRIMARY KEY,
            path TEXT NOT NULL UNIQUE,
            added_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS photos (
            id INTEGER PRIMARY KEY,
            folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
            path TEXT NOT NULL UNIQUE,
            file_size INTEGER NOT NULL,
            fingerprint TEXT NOT NULL,
            capture_date REAL,
            metadata TEXT,
            missing INTEGER NOT NULL DEFAULT 0,
            added_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS photos_fingerprint ON photos(fingerprint);
        CREATE INDEX IF NOT EXISTS photos_folder ON photos(folder_id);
        CREATE TABLE IF NOT EXISTS versions (
            id INTEGER PRIMARY KEY,
            photo_id INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
            name TEXT NOT NULL,
            decoder_id TEXT NOT NULL,
            decode_options TEXT NOT NULL,
            settings TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS versions_photo ON versions(photo_id);
        CREATE TABLE IF NOT EXISTS exports (
            id INTEGER PRIMARY KEY,
            version_id INTEGER NOT NULL REFERENCES versions(id) ON DELETE CASCADE,
            path TEXT NOT NULL,
            format TEXT NOT NULL,
            settings_hash TEXT NOT NULL,
            exported_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS exports_version ON exports(version_id);
        CREATE TABLE IF NOT EXISTS preferences (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)
    }

    // MARK: - 設定

    public var exportRoot: URL {
        get {
            locked {
                let rows = try? db.query("SELECT value FROM preferences WHERE key = 'export_root'")
                return rows?.first?[0].text.map { URL(fileURLWithPath: $0) } ?? Self.defaultExportRoot
            }
        }
        set {
            locked {
                _ = try? db.run("INSERT OR REPLACE INTO preferences (key, value) VALUES ('export_root', ?)",
                                [.text(newValue.path)])
            }
        }
    }

    // MARK: - フォルダ

    public func folders() throws -> [LibraryFolder] {
        try locked {
            try db.query("SELECT id, path, added_at FROM folders ORDER BY path").map {
                LibraryFolder(id: $0[0].int!, path: $0[1].text!,
                              addedAt: Date(timeIntervalSince1970: $0[2].double ?? 0))
            }
        }
    }

    /// 登録済みならそれを返す
    @discardableResult
    public func addFolder(_ url: URL) throws -> LibraryFolder {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return try locked {
            try db.run("INSERT OR IGNORE INTO folders (path, added_at) VALUES (?, ?)",
                       [.text(path), .double(Date().timeIntervalSince1970)])
            return try folders().first { $0.path == path }!
        }
    }

    /// フォルダの登録を外す。そのフォルダの写真の現像バージョンと書き出し履歴も消える(RAW と書き出したファイルは残る)
    public func removeFolder(id: Int64) throws {
        try locked { _ = try db.run("DELETE FROM folders WHERE id = ?", [.int(id)]) }
    }

    // MARK: - 写真

    private static let photoColumns = """
        p.id, p.folder_id, p.path, p.file_size, p.fingerprint, p.capture_date, p.metadata, p.missing,
        (SELECT COUNT(*) FROM versions v WHERE v.photo_id = p.id)
        """

    /// folderID が nil ならすべて。撮影日時順
    public func photos(folderID: Int64? = nil) throws -> [Photo] {
        try locked {
            let sql = "SELECT \(Self.photoColumns) FROM photos p "
                + (folderID == nil ? "" : "WHERE p.folder_id = ? ")
                + "ORDER BY p.capture_date, p.path"
            return try db.query(sql, folderID.map { [.int($0)] } ?? []).map(Self.photo)
        }
    }

    public func photo(id: Int64) throws -> Photo? {
        try locked {
            try db.query("SELECT \(Self.photoColumns) FROM photos p WHERE p.id = ?", [.int(id)])
                .first.map(Self.photo)
        }
    }

    public func photo(path: String) throws -> Photo? {
        try locked {
            try db.query("SELECT \(Self.photoColumns) FROM photos p WHERE p.path = ?", [.text(path)])
                .first.map(Self.photo)
        }
    }

    func photos(fingerprint: String) throws -> [Photo] {
        try locked {
            try db.query("SELECT \(Self.photoColumns) FROM photos p WHERE p.fingerprint = ?",
                         [.text(fingerprint)]).map(Self.photo)
        }
    }

    private static func photo(_ r: [SQLValue]) -> Photo {
        let metadata = r[6].text.flatMap { try? JSONDecoder().decode(RawMetadata.self, from: Data($0.utf8)) }
        return Photo(
            id: r[0].int!, folderID: r[1].int!, path: r[2].text!, fileSize: r[3].int ?? 0,
            fingerprint: r[4].text ?? "", captureDate: r[5].double.map { Date(timeIntervalSince1970: $0) },
            metadata: metadata, isMissing: (r[7].int ?? 0) != 0, versionCount: Int(r[8].int ?? 0))
    }

    // MARK: - 現像バージョン

    public func versions(photoID: Int64) throws -> [DevelopVersion] {
        try locked {
            try db.query("""
                SELECT id, photo_id, name, decoder_id, decode_options, settings, created_at, updated_at
                FROM versions WHERE photo_id = ? ORDER BY id
                """, [.int(photoID)]).map(Self.version)
        }
    }

    public func version(id: Int64) throws -> DevelopVersion? {
        try locked {
            try db.query("""
                SELECT id, photo_id, name, decoder_id, decode_options, settings, created_at, updated_at
                FROM versions WHERE id = ?
                """, [.int(id)]).first.map(Self.version)
        }
    }

    /// 新しいバージョンを作る。base を渡すとその内容をコピー(複製)
    @discardableResult
    public func createVersion(photoID: Int64, name: String? = nil, from base: DevelopVersion? = nil,
                              decoderID: String = Catalog.defaultDecoderID,
                              decodeOptions: DecodeOptions = DecodeOptions(),
                              settings: DevelopSettings = DevelopSettings()) throws -> DevelopVersion {
        try locked {
            let count = try versions(photoID: photoID).count
            let name = name ?? (base.map { "\($0.name) のコピー" } ?? "現像 \(count + 1)")
            let now = Date().timeIntervalSince1970
            try db.run("""
                INSERT INTO versions (photo_id, name, decoder_id, decode_options, settings, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, [
                    .int(photoID), .text(name),
                    .text(base?.decoderID ?? decoderID),
                    .text(Self.json(base?.decodeOptions ?? decodeOptions)),
                    .text(Self.json(base?.settings ?? settings)),
                    .double(now), .double(now),
                ])
            return try version(id: db.lastInsertID)!
        }
    }

    /// 名前・デコーダー・設定を保存
    public func updateVersion(_ v: DevelopVersion) throws {
        try locked {
            _ = try db.run("""
                UPDATE versions SET name = ?, decoder_id = ?, decode_options = ?, settings = ?, updated_at = ?
                WHERE id = ?
                """, [.text(v.name), .text(v.decoderID), .text(Self.json(v.decodeOptions)),
                      .text(Self.json(v.settings)), .double(Date().timeIntervalSince1970), .int(v.id)])
        }
    }

    public func deleteVersion(id: Int64) throws {
        try locked { _ = try db.run("DELETE FROM versions WHERE id = ?", [.int(id)]) }
    }

    private static func version(_ r: [SQLValue]) -> DevelopVersion {
        DevelopVersion(
            id: r[0].int!, photoID: r[1].int!, name: r[2].text ?? "",
            decoderID: r[3].text ?? defaultDecoderID,
            decodeOptions: decode(r[4].text) ?? DecodeOptions(),
            settings: decode(r[5].text) ?? DevelopSettings(),
            createdAt: Date(timeIntervalSince1970: r[6].double ?? 0),
            updatedAt: Date(timeIntervalSince1970: r[7].double ?? 0))
    }

    // MARK: - 書き出し履歴

    func recordExport(versionID: Int64, url: URL, format: ExportFormat, hash: String) throws {
        try locked {
            _ = try db.run("""
                INSERT INTO exports (version_id, path, format, settings_hash, exported_at) VALUES (?, ?, ?, ?, ?)
                """, [.int(versionID), .text(url.path), .text(format.rawValue), .text(hash),
                      .double(Date().timeIntervalSince1970)])
        }
    }

    public func exports(versionID: Int64) throws -> [ExportRecord] {
        try locked {
            try db.query("""
                SELECT id, version_id, path, format, settings_hash, exported_at
                FROM exports WHERE version_id = ? ORDER BY exported_at DESC
                """, [.int(versionID)]).map {
                ExportRecord(id: $0[0].int!, versionID: $0[1].int!, path: $0[2].text!, format: $0[3].text!,
                             settingsHash: $0[4].text!, exportedAt: Date(timeIntervalSince1970: $0[5].double!))
            }
        }
    }

    /// そのパスがこのバージョンの過去の書き出し先か(上書きしてよいかの判定)
    func isExportPath(_ url: URL, of versionID: Int64) throws -> Bool {
        try locked {
            try !db.query("SELECT 1 FROM exports WHERE version_id = ? AND path = ? LIMIT 1",
                          [.int(versionID), .text(url.path)]).isEmpty
        }
    }

    /// 写真ごとの書き出し状態
    public func exportStates() throws -> [Int64: ExportState] {
        try locked {
            let rows = try db.query("""
                SELECT v.id, v.photo_id, v.name, v.decoder_id, v.decode_options, v.settings, v.created_at, v.updated_at,
                  (SELECT e.settings_hash FROM exports e WHERE e.version_id = v.id ORDER BY e.exported_at DESC LIMIT 1)
                FROM versions v
                """)
            var states: [Int64: ExportState] = [:]
            for r in rows {
                let v = Self.version(r)
                guard let lastHash = r[8].text else { continue }
                if lastHash != v.contentHash {
                    states[v.photoID] = .needsReexport
                } else if states[v.photoID] == nil {
                    states[v.photoID] = .upToDate
                }
            }
            return states
        }
    }

    // MARK: - JSON

    static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: (try? encoder.encode(value)) ?? Data("{}".utf8), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ text: String?) -> T? {
        text.flatMap { try? JSONDecoder().decode(T.self, from: Data($0.utf8)) }
    }
}
