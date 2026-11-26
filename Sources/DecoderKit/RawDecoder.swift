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
    func decode(_ url: URL, options: DecodeOptions) throws -> DecodedImage
    func metadata(_ url: URL) throws -> RawMetadata
}

public extension RawDecoder {
    func canDecode(_ url: URL) -> Bool {
        RawFiles.extensions.contains(url.pathExtension.lowercased())
    }
}

public struct DecodeOptions: Hashable, Sendable, Codable {
    /// LibRaw のみ有効。Core Image は内部実装固定。
    public var demosaic: DemosaicMethod = .auto
    public var applyAsShotWB = true
    /// プレビュー用の半分サイズ(速い)
    public var halfSize = false
    /// デコーダー内蔵のノイズリダクション 0...1(0 = オフ)。D5 の高感度比較用。
    public var noiseReduction: Double = 0

    public init(demosaic: DemosaicMethod = .auto, applyAsShotWB: Bool = true,
                halfSize: Bool = false, noiseReduction: Double = 0) {
        self.demosaic = demosaic
        self.applyAsShotWB = applyAsShotWB
        self.halfSize = halfSize
        self.noiseReduction = noiseReduction
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
    public static let extensions: Set<String> = ["nef", "nrw", "cr2", "cr3", "arw", "orf", "dng"]

    public static func list(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
