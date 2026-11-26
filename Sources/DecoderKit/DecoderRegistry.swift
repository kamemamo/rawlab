import Foundation

/// 使えるデコーダーの一覧と、フォールバック付きのデコード。
/// rawler などを足すときは `all` に追加するだけ。
public enum DecoderRegistry {
    public static let all: [any RawDecoder] = [
        CoreImageDecoder(),
        LibRawDecoder(),
        RawlerDecoder(),
        RawLabEngineDecoder(),
    ]

    public static var ids: [String] { all.map(\.id) }

    public static func decoder(id: String) -> (any RawDecoder)? {
        all.first { $0.id == id }
    }

    /// 指定したデコーダーで失敗したら、残りを順番に試す。
    /// 戻り値の decoderID を見れば、実際にどれで開いたかがわかる。
    public static func decode(
        _ url: URL, preferred id: String, options: DecodeOptions
    ) throws -> DecodedImage {
        let ordered = all.filter { $0.id == id } + all.filter { $0.id != id }
        var errors: [String] = []
        for decoder in ordered where decoder.canDecode(url) {
            do {
                return try decoder.decode(url, options: options)
            } catch {
                errors.append("\(decoder.id): \(error.localizedDescription)")
            }
        }
        throw DecoderError.failed("どのデコーダーでも開けませんでした\n" + errors.joined(separator: "\n"))
    }

    /// メタデータは LibRaw の方が詳しい(ピクチャーコントロール等)ので優先。
    public static func metadata(_ url: URL) throws -> RawMetadata {
        let ci = try? CoreImageDecoder().metadata(url)
        guard var meta = try? LibRawDecoder().metadata(url) else {
            if let ci { return ci }
            throw DecoderError.unsupported(url)
        }
        // LibRaw で取れなかった項目は ImageIO の EXIF で補う
        if meta.lens.isEmpty { meta.lens = ci?.lens ?? "" }
        if meta.captureDate == nil { meta.captureDate = ci?.captureDate }
        return meta
    }
}
