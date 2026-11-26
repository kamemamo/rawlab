import Foundation

/// 「元ファイルは触らない」編集。RAW の隣に <名前>.NEF.rawlab.json として保存する。
/// どのデコーダーで現像したかも残すので、同じ結果を再現できる。
public struct Sidecar: Codable, Sendable {
    public var version = 1
    public var decoderID: String
    public var decodeOptions: DecodeOptions
    public var settings: DevelopSettings

    public init(decoderID: String, decodeOptions: DecodeOptions, settings: DevelopSettings) {
        self.decoderID = decoderID
        self.decodeOptions = decodeOptions
        self.settings = settings
    }

    public static func url(for raw: URL) -> URL {
        raw.appendingPathExtension("rawlab.json")
    }

    public static func load(for raw: URL) -> Sidecar? {
        guard let data = try? Data(contentsOf: url(for: raw)) else { return nil }
        return try? JSONDecoder().decode(Sidecar.self, from: data)
    }

    public func save(for raw: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(for: raw), options: .atomic)
    }
}
