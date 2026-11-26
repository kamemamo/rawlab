import AppKit
import CoreImage
import DecoderKit
import LibraryKit
import Observation

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

enum SidebarItem: Hashable {
    case all
    case folder(Int64)
}

@Observable @MainActor
final class AppModel {
    let catalog: Catalog?

    // ライブラリ
    var folders: [LibraryFolder] = []
    var sidebarSelection: SidebarItem? = .all {
        didSet { if oldValue != sidebarSelection { reloadPhotos() } }
    }
    var photos: [Photo] = []
    var exportStates: [Int64: ExportState] = [:]
    var folderCounts: [Int64: Int] = [:]
    var thumbnails: [Int64: CGImage] = [:]
    var isScanning = false
    var selectedPhotoID: Int64? {
        didSet { if oldValue != selectedPhotoID { photoSelectionChanged() } }
    }
    var selectedPhoto: Photo? { photos.first { $0.id == selectedPhotoID } }

    // 現像バージョン
    var versions: [DevelopVersion] = []
    var currentVersionID: Int64? {
        didSet { if oldValue != currentVersionID { versionSelectionChanged() } }
    }
    var currentVersion: DevelopVersion? { versions.first { $0.id == currentVersionID } }
    var lastExport: ExportRecord?

    // 現在のバージョンの内容(編集するとカタログへ自動保存)
    var decoderID = Catalog.defaultDecoderID {
        didSet { if oldValue != decoderID { decodeSettingsChanged() } }
    }
    var decodeOptions = DecodeOptions() {
        didSet { if oldValue != decodeOptions { decodeSettingsChanged() } }
    }
    var settings = DevelopSettings() {
        didSet { if oldValue != settings { rerender(); scheduleSave() } }
    }

    // 比較(表示だけの設定なので保存しない)
    var compareEnabled = false { didSet { if oldValue != compareEnabled { redecode() } } }
    var compareDecoderID = "coreimage" { didSet { if compareEnabled, oldValue != compareDecoderID { redecode() } } }

    // 書き出し
    var exportFormat = ExportFormat.jpeg
    var exportRoot: URL { catalog?.exportRoot ?? Catalog.defaultExportRoot }
    var isExporting = false

    // 表示
    var previews: [Preview] = []
    var isDecoding = false
    var status = ""

    private static let previewMaxPixel: CGFloat = 2400
    private var bases: [PreviewBase] = []
    private var decodeTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var loadingVersion = false

    init() {
        do {
            catalog = try Catalog()
        } catch {
            catalog = nil
            status = "ライブラリを開けません: \(error.localizedDescription)"
        }
    }

    // MARK: - 起動

    func start() {
        guard let catalog else { return }
        // `RawLab --args <フォルダ>` で起動したらそのフォルダを登録
        if let arg = CommandLine.arguments.dropFirst().first {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: arg, isDirectory: &isDir), isDir.boolValue {
                _ = try? catalog.addFolder(URL(fileURLWithPath: arg))
            }
        }
        reloadFolders()
        rescanAll()
    }

    // MARK: - フォルダ

    func reloadFolders() {
        folders = (try? catalog?.folders()) ?? []
        reloadPhotos()
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "ライブラリに追加"
        panel.message = "RAW の入ったフォルダを選んでください(サブフォルダも含みます。RAW は移動・変更しません)"
        guard panel.runModal() == .OK, let catalog else { return }
        var added: [LibraryFolder] = []
        for url in panel.urls {
            if let f = try? catalog.addFolder(url) { added.append(f) }
        }
        reloadFolders()
        if let first = added.first { sidebarSelection = .folder(first.id) }
        scan(added.map(\.id))
    }

    func rescanAll() {
        scan(folders.map(\.id))
    }

    private func scan(_ folderIDs: [Int64]) {
        guard let catalog, !folderIDs.isEmpty else { return }
        isScanning = true
        status = "スキャン中…"
        Task {
            let summaries = await Task.detached(priority: .userInitiated) { () -> [String] in
                folderIDs.compactMap { id in
                    guard let r = try? catalog.scan(folderID: id) else { return nil }
                    let name = (try? catalog.folders().first { $0.id == id }?.name) ?? ""
                    return "\(name): \(r.summary)"
                }
            }.value
            isScanning = false
            status = summaries.joined(separator: "\n")
            reloadPhotos()
        }
    }

    /// フォルダの登録を外す(RAW と書き出したファイルは残る。現像データは消える)
    func removeFolder(_ folder: LibraryFolder) {
        try? catalog?.removeFolder(id: folder.id)
        if sidebarSelection == .folder(folder.id) { sidebarSelection = .all }
        reloadFolders()
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - 写真一覧

    func reloadPhotos() {
        guard let catalog else { return }
        let folderID: Int64? = if case .folder(let id) = sidebarSelection { id } else { nil }
        photos = (try? catalog.photos(folderID: folderID)) ?? []
        exportStates = (try? catalog.exportStates()) ?? [:]
        let all = (try? catalog.photos()) ?? []
        folderCounts = Dictionary(grouping: all, by: \.folderID).mapValues(\.count)
        if selectedPhotoID == nil || !photos.contains(where: { $0.id == selectedPhotoID }) {
            selectedPhotoID = photos.first?.id
        }
    }

    func loadThumbnail(for photo: Photo) async {
        guard thumbnails[photo.id] == nil, !photo.isMissing else { return }
        let url = photo.url
        let thumb = await Task.detached(priority: .utility) { RawThumbnail.make(url, maxPixel: 320) }.value
        if let thumb { thumbnails[photo.id] = thumb }
    }


    // MARK: - 選択とバージョン

    private func photoSelectionChanged() {
        flushSave()
        previews = []
        bases = []
        versions = []
        guard let photo = selectedPhoto else {
            currentVersionID = nil
            return
        }
        versions = (try? catalog?.versions(photoID: photo.id)) ?? []
        if versions.isEmpty, let v = try? catalog?.createVersion(photoID: photo.id) {
            versions = [v]
        }
        if currentVersionID == versions.first?.id {
            versionSelectionChanged()  // 同じ ID でも写真が変わったので読み直す
        } else {
            currentVersionID = versions.first?.id
        }
    }

    private func versionSelectionChanged() {
        flushSave()
        guard let v = currentVersion else { return }
        loadingVersion = true
        decoderID = v.decoderID
        decodeOptions = v.decodeOptions
        settings = v.settings
        loadingVersion = false
        lastExport = try? catalog?.exports(versionID: v.id).first
        redecode()
    }

    func newVersion() {
        guard let photo = selectedPhoto, let v = try? catalog?.createVersion(photoID: photo.id) else { return }
        versionsChanged(select: v.id)
    }

    func duplicateVersion() {
        flushSave()
        guard let photo = selectedPhoto, let current = currentVersion,
              let v = try? catalog?.createVersion(photoID: photo.id, from: current) else { return }
        versionsChanged(select: v.id)
    }

    func renameCurrentVersion(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, var v = currentVersion, v.name != trimmed else { return }
        flushSave()
        v.name = trimmed
        try? catalog?.updateVersion(v)
        versionsChanged(select: v.id)
    }

    func deleteCurrentVersion() {
        guard let v = currentVersion, versions.count > 1 else { return }
        saveTask?.cancel()
        try? catalog?.deleteVersion(id: v.id)
        versionsChanged(select: nil)
    }

    private func versionsChanged(select id: Int64?) {
        guard let photo = selectedPhoto else { return }
        versions = (try? catalog?.versions(photoID: photo.id)) ?? []
        currentVersionID = id ?? versions.first?.id
        refreshPhotoRow()
    }

    /// 一覧のバッジ(バージョン数・書き出し状態)を更新
    private func refreshPhotoRow() {
        guard let id = selectedPhotoID, let updated = try? catalog?.photo(id: id),
              let i = photos.firstIndex(where: { $0.id == id }) else { return }
        photos[i] = updated
        exportStates = (try? catalog?.exportStates()) ?? [:]
    }

    // MARK: - 保存

    private func decodeSettingsChanged() {
        redecode()
        scheduleSave()
    }

    private func pendingVersion() -> DevelopVersion? {
        guard var v = currentVersion else { return nil }
        v.decoderID = decoderID
        v.decodeOptions = decodeOptions
        v.settings = settings
        return v
    }

    private func scheduleSave() {
        guard !loadingVersion else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            save()
        }
    }

    /// 選択を切り替える前に、未保存の変更を書き込む
    private func flushSave() {
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        save()
    }

    private func save() {
        saveTask = nil
        guard let v = pendingVersion(), let i = versions.firstIndex(where: { $0.id == v.id }),
              versions[i].contentHash != v.contentHash else { return }
        try? catalog?.updateVersion(v)
        versions[i] = v
        exportStates = (try? catalog?.exportStates()) ?? [:]
    }

    func resetSettings() {
        settings = DevelopSettings()
    }

    // MARK: - デコードと描画

    /// RAW を読み直す(デコーダー・デコードオプション・比較の変更時)
    func redecode() {
        guard !loadingVersion, let photo = selectedPhoto else { return }
        decodeTask?.cancel()
        if photo.isMissing {
            previews = []
            bases = []
            isDecoding = false
            status = "RAW が見つかりません: \(photo.path)"
            return
        }
        isDecoding = true
        let url = photo.url
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
            if !errors.isEmpty { status = errors.joined(separator: "\n") }
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

    // MARK: - 書き出し(書き出し先フォルダへ自動で振り分け、履歴を残す)

    func chooseExportRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = exportRoot
        panel.prompt = "書き出し先にする"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        catalog?.exportRoot = url
        status = "書き出し先: \(url.path)"
    }

    func export() {
        flushSave()
        guard let catalog, let photo = selectedPhoto, let version = currentVersion, !photo.isMissing else { return }
        let format = exportFormat
        isExporting = true
        status = "書き出し中…"
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try catalog.export(photo: photo, version: version, format: format) }
            }.value
            isExporting = false
            switch result {
            case .success(let r):
                status = "書き出し完了 (\(r.decoderID)): \(r.url.lastPathComponent)"
                lastExport = try? catalog.exports(versionID: version.id).first
                exportStates = (try? catalog.exportStates()) ?? [:]
            case .failure(let error):
                status = "書き出し失敗: \(error.localizedDescription)"
            }
        }
    }

    var currentNeedsReexport: Bool {
        guard let last = lastExport, let v = pendingVersion() else { return false }
        return last.settingsHash != v.contentHash
    }

    func displayName(for id: String) -> String {
        DecoderRegistry.decoder(id: id)?.displayName ?? id
    }
}
