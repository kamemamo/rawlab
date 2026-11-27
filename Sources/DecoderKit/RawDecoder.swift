import CoreImage
import Foundation

/// すべてのデコーダーが守る契約:
/// 「リニア(トーンカーブなし)・デモザイク済み・as-shot WB 適用済みの RGB」を CIImage で返す。
/// 露出やトーンなどの「見た目」は DevelopPipeline が共通で担当するので、
/// デコーダーを替えても同じ設定で公平に比較できる。
public protocol RawDecoder: Sendable {
    /// "coreimage" / "libraw" など。CLI の --decoder やサイドカーに使う。
    var id: String { get }
    var displayName: String { get }
    func canDecode(_ url: URL) -> Bool
    /// このファイルを開けない理由(開けるなら nil)。開く前に分かるものだけ
    func unsupportedReason(_ url: URL) -> String?
    func decode(_ url: URL, options: DecodeOptions) throws -> DecodedImage
    func metadata(_ url: URL) throws -> RawMetadata
}

public extension RawDecoder {
    func canDecode(_ url: URL) -> Bool {
        RawFiles.extensions.contains(url.pathExtension.lowercased()) && unsupportedReason(url) == nil
    }

    func unsupportedReason(_ url: URL) -> String? { nil }
}

public struct DecodeOptions: Hashable, Sendable, Codable {
    /// LibRaw のみ有効。Core Image は内部実装固定。
    public var demosaic: DemosaicMethod = .auto
    public var applyAsShotWB = true
    /// プレビュー用の半分サイズ(速い)
    public var halfSize = false
    /// デコーダー内蔵のノイズリダクション 0...1(0 = オフ)。D5 の高感度比較用。
    public var noiseReduction: Double = 0
    /// 白飛びの扱い(RawLab エンジン・RawLab ネイティブ・LibRaw で有効)
    public var highlight: HighlightMode = .clip

    public init(demosaic: DemosaicMethod = .auto, applyAsShotWB: Bool = true,
                halfSize: Bool = false, noiseReduction: Double = 0) {
        self.demosaic = demosaic
        self.applyAsShotWB = applyAsShotWB
        self.halfSize = halfSize
        self.noiseReduction = noiseReduction
    }
}

/// 白飛びの扱い
public enum HighlightMode: String, CaseIterable, Sendable, Codable {
    /// 1 色でも飽和したら白にする(従来どおり)
    case clip
    /// 飽和していない色と周りの色合いから、飽和した色を推定して補う。1 を超える明るさも残す
    case reconstruct

    public var title: String {
        switch self {
        case .clip: "切り捨て(白)"
        case .reconstruct: "色を補って復元"
        }
    }
}

public enum DemosaicMethod: String, CaseIterable, Sendable, Codable {
    case auto, linear, vng, ppg, ahd, dcb, dht, aahd

    /// LibRaw の params.user_qual の値
    var librawQuality: Int32 {
        switch self {
        case .auto: -1
        case .linear: 0
        case .vng: 1
        case .ppg: 2
        case .ahd: 3
        case .dcb: 4
        case .dht: 11
        case .aahd: 12
        }
    }
}

public struct DecodedImage: @unchecked Sendable {
    /// Core Image の作業空間(リニア)上の画像
    public let image: CIImage
    public let metadata: RawMetadata
    public let decoderID: String
    public let options: DecodeOptions
    /// デコードにかかった時間(秒)
    public let decodeTime: TimeInterval
}

public struct RawMetadata: Sendable, Codable {
    public var make = ""
    public var model = ""
    public var lens = ""
    public var iso: Double = 0
    public var shutter: Double = 0  // 秒
    public var aperture: Double = 0
    public var focalLength: Double = 0
    public var captureDate: Date?
    public var width = 0
    public var height = 0
    /// ニコンのピクチャーコントロール名(LibRaw で取得)
    public var pictureControl: String?
    public var activeDLighting: String?

    public init() {}

    public var shutterString: String {
        guard shutter > 0 else { return "-" }
        return shutter >= 1 ? String(format: "%.1fs", shutter) : "1/\(Int((1 / shutter).rounded()))"
    }

    public var summary: String {
        let parts = [
            "\(make) \(model)".trimmingCharacters(in: .whitespaces),
            lens.isEmpty ? nil : lens,
            iso > 0 ? "ISO \(Int(iso))" : nil,
            shutterString,
            aperture > 0 ? String(format: "f/%.1f", aperture) : nil,
            focalLength > 0 ? "\(Int(focalLength))mm" : nil,
        ]
        return parts.compactMap { $0 }.joined(separator: "  ")
    }
}

public enum DecoderError: LocalizedError {
    case unsupported(URL)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let url): "対応していないファイル: \(url.lastPathComponent)"
        case .failed(let message): message
        }
    }
}

public enum RawFiles {
    /// メーカーごとの拡張子(一覧表示・README 用)
    public static let formats: [(maker: String, extensions: [String])] = [
        ("Nikon", ["nef", "nrw"]),
        ("Canon", ["cr3", "cr2", "crw"]),
        ("Sony", ["arw", "srf", "sr2"]),
        ("OM System / Olympus", ["orf"]),
        ("Fujifilm", ["raf"]),
        ("Panasonic / Leica", ["rw2", "raw", "rwl"]),
        ("Pentax / Ricoh", ["pef", "ptx"]),
        ("Samsung", ["srw"]),
        ("Hasselblad", ["3fr", "fff"]),
        ("Phase One / Leaf / Mamiya", ["iiq", "mos", "mef"]),
        ("Sigma", ["x3f"]),
        ("Minolta", ["mrw"]),
        ("Kodak / Epson", ["dcr", "kdc", "erf"]),
        ("DNG(Leica・Pentax・スマホなど)", ["dng"]),
    ]

    public static let extensions: Set<String> = Set(formats.flatMap(\.extensions))

    public static func list(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
