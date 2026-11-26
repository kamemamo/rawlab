import AppKit
import CoreImage
import DecoderKit
import LibraryKit
import Observation

/// 下のパネルに並べる 1 枚
struct Variation: Identifiable {
    let id: Int
    let value: Double
    let label: String
    let image: CGImage
    let isCurrent: Bool
}

/// ホワイトバランスのマス目の 1 枚(x: 色温度, y: 色かぶり)
struct GridVariation: Identifiable {
    let id: Int
    let x: Double
    let y: Double
    let image: CGImage
    let isCurrent: Bool
}

struct DecoderVariation: Identifiable {
    var id: String { decoderID }
    let decoderID: String
    let name: String
    let time: TimeInterval
    let image: CGImage
}

/// デコード結果をプレビュー用(長辺 2400)とサムネイル用(長辺 400)のビットマップに確定したもの
private struct DecodedBase: @unchecked Sendable {
    let decoderID: String
    let image: CIImage
    let small: CIImage
    let time: TimeInterval
}

private struct ImageBox: @unchecked Sendable {
    let image: CIImage
}

/// 補正前との比較
enum CompareMode: Hashable {
    case off      // 補正後だけ
    case before   // 補正前だけ
    case split    // 左が補正前、右が補正後
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
        didSet {
            if oldValue != settings {
                rerender()
                refreshVariations()
                scheduleSave()
            }
        }
    }

    // 下のパネル
    var selectedTab: AdjustTab = .exposure {
        didSet {
            guard oldValue != selectedTab else { return }
            // マウスを乗せたままタブを替えたとき、大画面が仮の値のまま残らないようにする
            if hoverSettings != nil || hoverDecoderID != nil {
                hoverSettings = nil
                hoverDecoderID = nil
                rerender()
            }
            variations = []  // 前のタブのサムネイルを残さない
            gridVariations = []
            refreshVariations()
        }
    }
    /// 細かい段階で表示中のタブ
    var fineTabs: Set<AdjustTab> = []
    var variations: [Variation] = []
    var gridVariations: [GridVariation] = []
    var gridColumns: [Double] = []
    var gridRows: [Double] = []
    var decoderVariations: [DecoderVariation] = []
    var isLoadingVariations = false
    /// 等倍で切り出す場所(画像に対する割合、左上原点)
    var cropCenter = CGPoint(x: 0.5, y: 0.5)
    static let cropSide: CGFloat = 220

    // マウスを乗せている間だけ大画面に反映する値
    private var hoverSettings: DevelopSettings?
    private var hoverDecoderID: String?

    // 書き出し
    var exportFormat = ExportFormat.jpeg
    var exportRoot: URL { catalog?.exportRoot ?? Catalog.defaultExportRoot }
    var isExporting = false

    // 補正前との比較
    var compareMode = CompareMode.off {
        didSet { if compareMode != .off, beforePreview == nil { renderBefore() } }
    }
    var beforePreview: CGImage?
    /// 左右で比較するときの境目(画像幅に対する割合)
    var splitPosition: CGFloat = 0.5

    // レベル表示(ヒストグラム)と白飛び・黒つぶれ表示
    var histogram: Histogram?
    var showClipping = false {
        didSet { if oldValue != showClipping { rerender() } }
    }
    var clippingOverlay: CGImage?

    // スポイト(ホワイトバランス)
    var isEyedropperActive = false

    // 表示
    var preview: CGImage?
    var previewDecoderID: String?
    var previewTime: TimeInterval = 0
    var isDecoding = false
    var status = ""

    private var base: DecodedBase?
    /// デコーダーごとのプレビュー(デコーダータブ用・切り替えを速くする)。写真とデコード設定が変わったら捨てる
    private var decoderBases: [String: DecodedBase] = [:]
    private var decoderBasesKey = ""
    /// 等倍切り出し用のフル解像度画像
    private var fullImage: ImageBox?
    private var fullImageKey = ""
    private var cropBase: ImageBox?
    private var cropTask: Task<Void, Never>?
    private var decodeTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var variationTask: Task<Void, Never>?
    private var decoderTask: Task<Void, Never>?
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
        preview = nil
        base = nil
        variations = []
        decoderVariations = []
        versions = []
        cropCenter = CGPoint(x: 0.5, y: 0.5)
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

    // MARK: - 下のパネルの操作

    /// サムネイルをクリック。粗い段階で選んだら細かい段階に切り替える
    func pick(_ value: Double) {
        guard let p = selectedTab.param else { return }
        hoverSettings = nil
        fineTabs.insert(selectedTab)
        var s = settings
        s[keyPath: p.keyPath] = p.clamp(value)
        if s == settings { refreshVariations() } else { settings = s }
    }

    /// マス目をクリック。色温度と色かぶりを同時に決める
    func pickGrid(x: Double, y: Double) {
        guard let g = selectedTab.grid else { return }
        hoverSettings = nil
        fineTabs.insert(selectedTab)
        var s = settings
        s[keyPath: g.x.keyPath] = g.x.clamp(x)
        s[keyPath: g.y.keyPath] = g.y.clamp(y)
        if s == settings { refreshVariations() } else { settings = s }
    }

    func hoverGrid(x: Double, y: Double, inside: Bool) {
        guard let g = selectedTab.grid else { return }
        var s = settings
        s[keyPath: g.x.keyPath] = x
        s[keyPath: g.y.keyPath] = y
        setHover(s, inside: inside)
    }

    /// ← → / − + で細かい刻みずつ動かす(ホワイトバランスでは色温度)
    func nudge(_ direction: Int) {
        guard let p = selectedTab.param ?? selectedTab.grid?.x else { return }
        settings[keyPath: p.keyPath] = p.clamp(settings[keyPath: p.keyPath] + Double(direction) * p.fineStep)
    }

    /// ↑ ↓(ホワイトバランスの色かぶり)
    func nudgeVertical(_ direction: Int) {
        guard let p = selectedTab.grid?.y else { return }
        settings[keyPath: p.keyPath] = p.clamp(settings[keyPath: p.keyPath] + Double(direction) * p.fineStep)
    }

    func resetCurrentParam() {
        if let g = selectedTab.grid {
            var s = settings
            s[keyPath: g.x.keyPath] = 0
            s[keyPath: g.y.keyPath] = 0
            settings = s
            return
        }
        guard let p = selectedTab.param else { return }
        settings[keyPath: p.keyPath] = p.clamp(0)
    }

    func gridLabel(_ axis: KeyPath<(x: AdjustParam, y: AdjustParam), AdjustParam>) -> String {
        guard let g = selectedTab.grid else { return "" }
        let p = g[keyPath: axis]
        return p.label(settings[keyPath: p.keyPath])
    }

    func toggleFine() {
        if fineTabs.contains(selectedTab) {
            fineTabs.remove(selectedTab)
        } else {
            fineTabs.insert(selectedTab)
        }
        refreshVariations()
    }

    var currentParamLabel: String {
        guard let p = selectedTab.param else { return "" }
        return p.label(settings[keyPath: p.keyPath])
    }

    /// サムネイルにマウスを乗せている間、大画面をその値で表示。
    /// 隣へ移るとき「入った」より後に「出た」が来ることがあるので、出たのが今表示中のものの場合だけ戻す
    func hover(_ value: Double, inside: Bool) {
        guard let p = selectedTab.param else { return }
        var s = settings
        s[keyPath: p.keyPath] = value
        setHover(s, inside: inside)
    }

    private func setHover(_ s: DevelopSettings, inside: Bool) {
        if inside {
            hoverSettings = s
        } else if hoverSettings == s {
            hoverSettings = nil
        } else {
            return
        }
        rerender()
    }

    func hoverDecoder(_ id: String, inside: Bool) {
        if inside {
            hoverDecoderID = id
        } else if hoverDecoderID == id {
            hoverDecoderID = nil
        } else {
            return
        }
        rerender()
    }

    func pickDecoder(_ id: String) {
        hoverDecoderID = nil
        decoderID = id
    }

    /// 大画面をクリックして等倍で見る場所を決める
    func setCropCenter(_ point: CGPoint) {
        cropCenter = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        cropBase = nil
        refreshVariations()
    }

    /// 大画面上の切り出し枠の幅(画像幅に対する割合)
    var cropFraction: CGFloat {
        let width = CGFloat(selectedPhoto?.metadata?.width ?? 0)
        return Self.cropSide / (width > 0 ? width : 5568)
    }

    // MARK: - デコードと描画

    private var optionsKey: String {
        "\(selectedPhotoID ?? 0)-\(decodeOptions.hashValue)"
    }

    /// RAW を読み直す(写真・デコーダー・デコード設定の変更時)
    func redecode() {
        guard !loadingVersion, let photo = selectedPhoto else { return }
        decodeTask?.cancel()
        cropTask?.cancel()
        cropTask = nil
        cropBase = nil
        if photo.isMissing {
            preview = nil
            base = nil
            variations = []
            isDecoding = false
            status = "RAW が見つかりません: \(photo.path)"
            return
        }
        if decoderBasesKey != optionsKey {
            decoderBases = [:]
            decoderBasesKey = optionsKey
        }
        // デコーダータブで一度読んだものは使い回す
        if let cached = decoderBases[decoderID] {
            setBase(cached)
            return
        }
        isDecoding = true
        let url = photo.url
        let id = decoderID
        let options = decodeOptions
        let key = optionsKey

        decodeTask = Task {
            // スライダー連打で何度もデコードしないよう少し待つ
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Self.makeBase(url: url, decoderID: id, options: options) }
            }.value
            guard !Task.isCancelled, key == optionsKey else { return }
            isDecoding = false
            switch result {
            case .success(let b):
                decoderBases[id] = b
                setBase(b)
            case .failure(let error):
                status = error.localizedDescription
            }
        }
    }

    private func setBase(_ b: DecodedBase) {
        base = b
        beforePreview = nil
        if compareMode != .off { renderBefore() }
        previewDecoderID = b.decoderID
        previewTime = b.time
        rerender()
        refreshVariations()
    }

    nonisolated private static func makeBase(url: URL, decoderID: String, options: DecodeOptions) throws -> DecodedBase {
        let start = Date()
        var o = options
        o.halfSize = true  // プレビューは半分サイズで十分
        let decoded = try DecoderRegistry.decode(url, preferred: decoderID, options: o)
        guard let big = DevelopPipeline.materialize(decoded.image, maxPixel: 2400),
              let small = DevelopPipeline.materialize(big, maxPixel: 400)
        else { throw DecoderError.failed("プレビュー作成に失敗") }
        return DecodedBase(decoderID: decoded.decoderID, image: big, small: small,
                           time: Date().timeIntervalSince(start))
    }

    /// 大画面を描き直す。確定済みのビットマップに当てるので速い
    func rerender() {
        renderTask?.cancel()
        guard let b = hoverDecoderID.flatMap({ decoderBases[$0] }) ?? base else { return }
        let box = ImageBox(image: b.image)
        let settings = hoverSettings ?? self.settings
        let clipping = showClipping
        renderTask = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (CGImage, Histogram?, CGImage?)? in
                guard let cg = DevelopPipeline.renderCGImage(DevelopPipeline.apply(settings, to: box.image))
                else { return nil }
                return (cg, Histogram.compute(from: cg), clipping ? Histogram.clippingOverlay(from: cg) : nil)
            }.value
            guard !Task.isCancelled, let result else { return }
            preview = result.0
            histogram = result.1
            clippingOverlay = result.2
        }
    }

    /// 補正前(同じデコーダーで補正をすべて 0 にしたもの)を描く
    private func renderBefore() {
        guard let b = base else { return }
        let box = ImageBox(image: b.image)
        Task {
            let cg = await Task.detached(priority: .userInitiated) {
                DevelopPipeline.renderCGImage(DevelopPipeline.apply(DevelopSettings(), to: box.image))
            }.value
            guard base?.image === box.image else { return }
            beforePreview = cg
        }
    }

    /// スポイトで大画面をクリック: その点が無彩色になる色温度・色かぶりにする
    func applyEyedropper(at point: CGPoint) {
        isEyedropperActive = false
        guard let b = base, let g = AdjustTab.whiteBalance.grid else { return }
        let box = ImageBox(image: b.image)
        let tRange = g.x.range, tiRange = g.y.range
        status = "スポイト: 計算中…"
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                DevelopPipeline.solveWhiteBalance(box.image, at: point,
                                                  temperatureRange: tRange, tintRange: tiRange)
            }.value
            guard let result else {
                status = "スポイト: 暗すぎるか白飛びしている場所です。白やグレーの部分をクリックしてください"
                return
            }
            var s = settings
            s[keyPath: g.x.keyPath] = g.x.clamp(result.temperature)
            s[keyPath: g.y.keyPath] = g.y.clamp(result.tint)
            fineTabs.insert(.whiteBalance)
            status = "スポイト: 色温度 \(g.x.label(s[keyPath: g.x.keyPath])) / 色かぶり \(g.y.label(s[keyPath: g.y.keyPath]))"
            settings = s
        }
    }

    /// 下のパネルのサムネイルを作り直す
    func refreshVariations() {
        guard !loadingVersion, base != nil else { return }
        if selectedTab == .decoder {
            loadDecoderVariations()
            return
        }
        if let g = selectedTab.grid, let base {
            renderGrid(g, source: base.small)
            return
        }
        guard let p = selectedTab.param, let base else { return }
        let source: CIImage
        if p.usesCrop {
            guard let crop = cropBase else {
                loadCrop()
                return
            }
            source = crop.image
        } else {
            source = base.small
        }

        variationTask?.cancel()
        let settings = self.settings
        let current = settings[keyPath: p.keyPath]
        let values = fineTabs.contains(selectedTab) ? p.fineValues(around: current) : p.coarseValues
        let box = ImageBox(image: source)
        variationTask = Task {
            try? await Task.sleep(for: .milliseconds(20))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { () -> [Variation] in
                values.enumerated().compactMap { i, v in
                    var s = settings
                    s[keyPath: p.keyPath] = v
                    guard let cg = DevelopPipeline.renderCGImage(DevelopPipeline.apply(s, to: box.image)) else { return nil }
                    return Variation(id: i, value: v, label: p.label(v), image: cg,
                                     isCurrent: abs(v - current) < p.fineStep / 2)
                }
            }.value
            guard !Task.isCancelled else { return }
            variations = result
        }
    }

    /// ホワイトバランスのマス目: 横に色温度 9 段階、縦に色かぶり 3 段階(上がプラス)
    private func renderGrid(_ g: (x: AdjustParam, y: AdjustParam), source: CIImage) {
        variationTask?.cancel()
        let settings = self.settings
        let cx = settings[keyPath: g.x.keyPath]
        let cy = settings[keyPath: g.y.keyPath]
        let fine = fineTabs.contains(selectedTab)
        let xs = fine ? g.x.fineValues(around: cx) : g.x.coarseValues
        let ys = Array((fine ? g.y.fineValues(around: cy) : g.y.coarseValues).reversed())
        let box = ImageBox(image: source)
        variationTask = Task {
            try? await Task.sleep(for: .milliseconds(20))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { () -> [GridVariation] in
                var items: [GridVariation] = []
                for (row, y) in ys.enumerated() {
                    for (col, x) in xs.enumerated() {
                        var s = settings
                        s[keyPath: g.x.keyPath] = x
                        s[keyPath: g.y.keyPath] = y
                        guard let cg = DevelopPipeline.renderCGImage(DevelopPipeline.apply(s, to: box.image)) else { continue }
                        items.append(GridVariation(
                            id: row * xs.count + col, x: x, y: y, image: cg,
                            isCurrent: abs(x - cx) < g.x.fineStep / 2 && abs(y - cy) < g.y.fineStep / 2))
                    }
                }
                return items
            }.value
            guard !Task.isCancelled else { return }
            gridColumns = xs
            gridRows = ys
            gridVariations = result
        }
    }

    /// 等倍切り出し用にフル解像度でデコードして、指定位置を切り出す
    private func loadCrop() {
        guard cropTask == nil, let photo = selectedPhoto else { return }
        isLoadingVariations = true
        let url = photo.url
        let id = decoderID
        var options = decodeOptions
        options.halfSize = false
        let center = cropCenter
        let key = "\(optionsKey)-\(id)"
        let cachedFull = fullImageKey == key ? fullImage : nil
        let side = Self.cropSide

        cropTask = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (ImageBox, ImageBox)? in
                let full: CIImage
                if let cachedFull {
                    full = cachedFull.image
                } else {
                    guard let d = try? DecoderRegistry.decode(url, preferred: id, options: options) else { return nil }
                    full = d.image
                }
                let e = full.extent
                let cx = e.minX + center.x * e.width
                let cy = e.maxY - center.y * e.height  // Core Image は左下原点
                let x = min(max(cx - side / 2, e.minX), e.maxX - side)
                let y = min(max(cy - side / 2, e.minY), e.maxY - side)
                let crop = full.cropped(to: CGRect(x: x, y: y, width: side, height: side).integral)
                let moved = crop.transformed(by: .init(translationX: -crop.extent.minX, y: -crop.extent.minY))
                guard let fixed = DevelopPipeline.materialize(moved, maxPixel: 10_000) else { return nil }
                return (ImageBox(image: full), ImageBox(image: fixed))
            }.value
            cropTask = nil
            isLoadingVariations = false
            guard !Task.isCancelled, let result, key == "\(optionsKey)-\(decoderID)" else { return }
            fullImage = result.0
            fullImageKey = key
            if center == cropCenter {
                cropBase = result.1
            }
            refreshVariations()
        }
    }

    /// 全デコーダーで読んで並べる(読んだものは切り替え用にも使い回す)
    private func loadDecoderVariations() {
        guard let photo = selectedPhoto, !photo.isMissing else { return }
        let missing = DecoderRegistry.all.map(\.id).filter { decoderBases[$0] == nil }
        renderDecoderVariations()
        guard !missing.isEmpty else { return }
        decoderTask?.cancel()
        isLoadingVariations = true
        let url = photo.url
        let options = decodeOptions
        let key = optionsKey
        decoderTask = Task {
            for id in missing {
                let b = await Task.detached(priority: .userInitiated) {
                    try? Self.makeBase(url: url, decoderID: id, options: options)
                }.value
                guard !Task.isCancelled, key == optionsKey else { return }
                if let b { decoderBases[id] = b }
                renderDecoderVariations()
            }
            isLoadingVariations = false
        }
    }

    private func renderDecoderVariations() {
        variationTask?.cancel()
        let items = DecoderRegistry.all.compactMap { d in
            decoderBases[d.id].map { (d.id, d.displayName, $0) }
        }
        let settings = self.settings
        variationTask = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> [DecoderVariation] in
                items.compactMap { id, name, b in
                    guard let cg = DevelopPipeline.renderCGImage(DevelopPipeline.apply(settings, to: b.small))
                    else { return nil }
                    return DecoderVariation(decoderID: id, name: name, time: b.time, image: cg)
                }
            }.value
            guard !Task.isCancelled else { return }
            decoderVariations = result
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
