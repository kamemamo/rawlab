import CryptoKit
import DecoderKit
import Foundation

/// ライブラリに登録した RAW フォルダ。RawLab はこの中を読むだけで、何も書き込まない。
public struct LibraryFolder: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let path: String
    public let addedAt: Date

    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { url.lastPathComponent }
    /// 外付けディスクが外れているときなどは false
    public var isAvailable: Bool { FileManager.default.fileExists(atPath: path) }
}

/// ライブラリ内の RAW 1 枚
public struct Photo: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let folderID: Int64
    public let path: String
    public let fileSize: Int64
    /// サイズ + 先頭 1MB の SHA-256。ファイルが移動・改名されたときの照合に使う
    public let fingerprint: String
    public let captureDate: Date?
    public let metadata: RawMetadata?
    /// 前回のスキャンで見つからなかった
    public let isMissing: Bool
    public let versionCount: Int

    public var url: URL { URL(fileURLWithPath: path) }
    public var fileName: String { url.lastPathComponent }

    public static func == (a: Photo, b: Photo) -> Bool {
        a.id == b.id && a.path == b.path && a.isMissing == b.isMissing && a.versionCount == b.versionCount
    }
    public func hash(into h: inout Hasher) { h.combine(id) }
}

/// 現像バージョン。1 枚の RAW に複数持てる(カラー版・モノクロ版など)
public struct DevelopVersion: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let photoID: Int64
    public var name: String
    public var decoderID: String
    public var decodeOptions: DecodeOptions
    public var settings: DevelopSettings
    public let createdAt: Date
    public var updatedAt: Date

    /// 現像結果を決める内容のハッシュ。書き出し時の値と比べて「要再書き出し」を判定する
    public var contentHash: String {
        struct Content: Encodable {
            let decoderID: String
            let decodeOptions: DecodeOptions
            let settings: DevelopSettings
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(Content(decoderID: decoderID, decodeOptions: decodeOptions, settings: settings))) ?? Data()
        return SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ExportRecord: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let versionID: Int64
    public let path: String
    public let format: String
    public let settingsHash: String
    public let exportedAt: Date

    public var url: URL { URL(fileURLWithPath: path) }
}

/// 写真ごとの書き出し状態(一覧のバッジ用)
public enum ExportState: Sendable {
    case notExported
    case upToDate
    /// 書き出した後に現像内容を変えたバージョンがある
    case needsReexport
}

public struct ScanResult: Sendable {
    public var total = 0
    public var added = 0
    public var relinked = 0
    public var missing = 0
    public var sidecarsImported = 0
    public var folderUnavailable = false

    public var summary: String {
        if folderUnavailable { return "フォルダが見つかりません(ディスクが外れていませんか?)" }
        var parts = ["\(total) 枚"]
        if added > 0 { parts.append("新規 \(added)") }
        if relinked > 0 { parts.append("移動を検出 \(relinked)") }
        if missing > 0 { parts.append("見つからない \(missing)") }
        if sidecarsImported > 0 { parts.append("サイドカー取り込み \(sidecarsImported)") }
        return parts.joined(separator: " / ")
    }
}
