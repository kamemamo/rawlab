import AppKit
import CoreImage
import DecoderKit
import Observation
import UniformTypeIdentifiers

struct Preview {
    let image: CGImage
    let decoderID: String
    /// デコード + プレビュー用ビットマップ確定までの時間
    let time: TimeInterval
}

private struct PreviewBase: @unchecked Sendable {
    let decoderID: String
    let image: CIImage
    let time: TimeInterval
}

@Observable @MainActor
final class AppModel {
    // ライブラリ
    var folder: URL?
    var files: [URL] = []
    var thumbnails: [URL: CGImage] = [:]
    var selection: URL? {
        didSet { if oldValue != selection { selectionChanged() } }
    }
    var metadata: RawMetadata?

    // デコーダー
    var decoderID = "libraw" { didSet { if oldValue != decoderID { decodeSettingsChanged() } } }
    var decodeOptions = DecodeOptions() { didSet { if oldValue != decodeOptions { decodeSettingsChanged() } } }
    var compareEnabled = false { didSet { if oldValue != compareEnabled { redecode() } } }
    var compareDecoderID = "coreimage" { didSet { if compareEnabled, oldValue != compareDecoderID { redecode() } } }

    // 現像
    var settings = DevelopSettings() {
        didSet { if oldValue != settings { rerender(); scheduleSidecarSave() } }
    }
    var exportFormat = ExportFormat.jpeg

    // 表示
    var previews: [Preview] = []
    var isDecoding = false
    var status = ""

    private static let previewMaxPixel: CGFloat = 2400
    private var bases: [PreviewBase] = []
    private var decodeTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var applyingSidecar = false

    // MARK: - フォルダ

    func openInitialFolder() {
        guard folder == nil else { return }
        // `swift run RawLabApp <フォルダ>` で起動時に開ける
        if let arg = CommandLine.arguments.dropFirst().first {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: arg, isDirectory: &isDir), isDir.boolValue {
                loadFolder(URL(fileURLWithPath: arg))
            }
        }
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "開く"
        if panel.runModal() == .OK, let url = panel.url { loadFolder(url) }
    }

    func loadFolder(_ url: URL) {
        folder = url
        files = RawFiles.list(in: url)
        thumbnails = [:]
        status = "\(files.count) 枚"
        selection = files.first
        let files = self.files
        Task {
            for file in files {
                let thumb = await Task.detached(priority: .utility) { RawThumbnail.make(file, maxPixel: 320) }.value
                if let thumb { thumbnails[file] = thumb }
            }
        }
    }

    // MARK: - 選択とサイドカー

    private func selectionChanged() {
        previews = []
        bases = []
        metadata = nil
        guard let url = selection else { return }

        applyingSidecar = true
        if let sidecar = Sidecar.load(for: url) {
            decoderID = sidecar.decoderID
            decodeOptions = sidecar.decodeOptions
            settings = sidecar.settings
        } else {
            settings = DevelopSettings()
        }
        applyingSidecar = false

        Task {
            metadata = await Task.detached { try? DecoderRegistry.metadata(url) }.value
        }
        redecode()
    }

    private func decodeSettingsChanged() {
        redecode()
        scheduleSidecarSave()
    }

    private func scheduleSidecarSave() {
        guard !applyingSidecar, let url = selection else { return }
        saveTask?.cancel()
        let sidecar = Sidecar(decoderID: decoderID, decodeOptions: decodeOptions, settings: settings)
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            try? sidecar.save(for: url)
        }
    }

    func resetSettings() {
        settings = DevelopSettings()
    }

    // MARK: - デコードと描画

    /// RAW を読み直す(デコーダー・デコードオプション・比較の変更時)
    func redecode() {
        guard !applyingSidecar, let url = selection else { return }
        decodeTask?.cancel()
        isDecoding = true
        let ids = compareEnabled ? [decoderID, compareDecoderID] : [decoderID]
        var options = decodeOptions
        options.halfSize = true  // プレビューは半分サイズで十分
        let maxPixel = Self.previewMaxPixel

        decodeTask = Task {
            // スライダー連打で何度もデコードしないよう少し待つ
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }

            var results: [PreviewBase] = []
            var errors: [String] = []
            for id in ids {
                let result = await Task.detached(priority: .userInitiated) { () -> Result<PreviewBase, Error> in
                    Result {
                        let start = Date()
                        let decoded = try DecoderRegistry.decode(url, preferred: id, options: options)
                        guard let base = DevelopPipeline.materialize(decoded.image, maxPixel: maxPixel)
                        else { throw DecoderError.failed("プレビュー作成に失敗") }
                        return PreviewBase(decoderID: decoded.decoderID, image: base,
                                           time: Date().timeIntervalSince(start))
                    }
                }.value
                guard !Task.isCancelled else { return }
                switch result {
                case .success(let base): results.append(base)
                case .failure(let error): errors.append(error.localizedDescription)
                }
            }
            bases = results
            isDecoding = false
            status = errors.isEmpty ? "" : errors.joined(separator: "\n")
            rerender()
        }
    }

    /// 現像設定だけ変わったとき。確定済みのビットマップに当てるので速い
    func rerender() {
        renderTask?.cancel()
        let bases = self.bases
        let settings = self.settings
        renderTask = Task {
            let rendered = await Task.detached(priority: .userInitiated) { () -> [Preview] in
                bases.compactMap { base in
                    let output = DevelopPipeline.apply(settings, to: base.image)
                    guard let cg = DevelopPipeline.renderCGImage(output) else { return nil }
                    return Preview(image: cg, decoderID: base.decoderID, time: base.time)
                }
            }.value
            guard !Task.isCancelled else { return }
            previews = rendered
        }
    }

    // MARK: - 書き出し(フル解像度で再デコード)

    func export() {
        guard let url = selection else { return }
        let panel = NSSavePanel()
        let format = exportFormat
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + "." + format.fileExtension
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .image]
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        let id = decoderID
        var options = decodeOptions
        options.halfSize = false
        let settings = self.settings
        status = "書き出し中…"
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                Result {
                    let decoded = try DecoderRegistry.decode(url, preferred: id, options: options)
                    try Exporter.export(DevelopPipeline.apply(settings, to: decoded.image), to: dest, format: format)
                    return decoded.decoderID
                }
            }.value
            switch result {
            case .success(let used): status = "書き出し完了 (\(used)): \(dest.lastPathComponent)"
            case .failure(let error): status = "書き出し失敗: \(error.localizedDescription)"
            }
        }
    }

    func displayName(for id: String) -> String {
        DecoderRegistry.decoder(id: id)?.displayName ?? id
    }
}
