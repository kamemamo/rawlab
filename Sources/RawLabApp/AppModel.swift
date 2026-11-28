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
    /// nil ならこのデコーダーでは開けない
    let image: CGImage?
    /// 開けない理由が前もって分かっていればその説明(JPEG XL の DNG など)
    var reason: String? = nil
    /// デコードの設定を変えて読み直している間、前の設定の絵を仮に出している
    var isStale = false
}

/// デコード結果をプレビュー用(長辺 2400)とサムネイル用(長辺 400)のビットマップに確定したもの
private struct DecodedBase: @unchecked Sendable {
    let decoderID: String
    let image: CIImage
    let small: CIImage
    let time: TimeInterval
    /// センサーの飽和の地図(RawLab エンジン・RawLab ネイティブのみ)
    var saturation: SensorSaturationOverlay? = nil
    /// 暗部について測った値(RawLab エンジン・RawLab ネイティブのみ)
    var darkInfo: DarkInfo? = nil
}

/// 大画面に重ねるセンサーの飽和の地図と、飽和した画素の割合
struct SensorSaturationOverlay: @unchecked Sendable {
    let image: CGImage
    /// [R, G, B]
    let fraction: [Double]
    let anyFraction: Double
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
            channelVariations = [[], [], []]
            refreshVariations()
        }
    }
    /// 細かい段階で表示中のタブ
    var fineTabs: Set<AdjustTab> = []
    var variations: [Variation] = []
    var gridVariations: [GridVariation] = []
    /// 3 段のサムネイル(色ごとの露出は R・G・B、色ごとの調整は 色相・彩度・明度)
    var channelVariations: [[Variation]] = [[], [], []]
    /// 色ごとの調整で選んでいる系統
    var selectedColorRange: ColorRange = .blue {
        didSet {
            if oldValue != selectedColorRange {
                channelVariations = [[], [], []]
                refreshVariations()
            }
        }
    }

    /// 3 段で表示する項目(該当しないタブでは nil)
    var rowParams: [AdjustParam]? {
        selectedTab == .hsl ? AdjustTab.hslParams(selectedColorRange) : selectedTab.channelParams
    }

    var rowTitles: [String] {
        selectedTab == .hsl ? ["色相", "彩度", "明度"] : ["R", "G", "B"]
    }
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
    /// センサーの段階で飽和した所を色で重ねる(R・G・B = その色が飽和、白 = 3 色とも)
    var showSensorSaturation = false
    /// いま大画面に出しているデコード結果の、センサーの飽和(出せないデコーダーなら nil)
    var sensorSaturation: SensorSaturationOverlay?
    /// いま大画面に出しているデコード結果の、暗部について測った値
    var darkInfo: DarkInfo?
    /// 大画面で見る色(RGB / R / G / B)
    var channelView = ChannelView.rgb {
        didSet {
            if oldValue != channelView {
                rerender()
                if compareMode != .off { renderBefore() }
            }
        }
    }

    /// レベル補正・トーンカーブ用: その 2 つをかける前の画像のヒストグラム
    var toneHistogram: Histogram?
    /// レベル補正・トーンカーブ用: 補正後(すべての補正をかけた)のヒストグラム
    var toneHistogramAfter: Histogram?

    // 虫眼鏡
    var loupeEnabled = false {
        didSet { if !loupeEnabled { loupePoint = nil; loupeImage = nil; loupeTask?.cancel() } }
    }
    /// 虫眼鏡の中心(画像に対する割合、左上原点)
    var loupePoint: CGPoint?
    var loupeImage: CGImage?
    private var loupePixelSize = 480
    private var loupeTask: Task<Void, Never>?
    private var fullImageTask: Task<ImageBox?, Never>?
    private var fullImageTaskKey = ""

    // スポイト(ホワイトバランス)
    var isEyedropperActive = false
    /// 色味をほかの写真に貼っている途中の進み具合
    var lookPasteProgress: (done: Int, total: Int)?
    var isLookPasteSheetShown = false

    // 表示
    var preview: CGImage?
    var previewDecoderID: String?
    var previewTime: TimeInterval = 0
    var isDecoding = false
    var status = ""

    private var base: DecodedBase?
    /// デコーダーごとのプレビュー(デコーダータブ用・切り替えを速くする)。写真とデコード設定が変わったら捨てる
    private var decoderBases: [String: DecodedBase] = [:]
    /// デコーダータブで「開けない」とわかったデコーダー(decoderBases と同じタイミングで捨てる)
    private var decoderFailures: Set<String> = []
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
            let c = try Catalog()
            catalog = c
            LookStore.directory = c.libraryURL.appendingPathComponent("Looks")
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

    /// 色ごとの調整: 全系統を 0 に戻す
    func resetAllColors() {
        settings.colorAdjustments = ColorAdjustments()
    }

    /// 大画面をクリック: その点の色の系統を選ぶ(色の薄い所では変えない)
    func pickColorRange(at point: CGPoint) {
        guard let image = preview else { return }
        let x = min(max(Int(point.x * CGFloat(image.width)), 0), image.width - 1)
        let y = min(max(Int(point.y * CGFloat(image.height)), 0), image.height - 1)
        // 5×5 の平均を sRGB で取り出す
        let size = 5
        var px = [UInt8](repeating: 0, count: size * size * 4)
        let rect = CGRect(x: max(x - 2, 0), y: max(y - 2, 0), width: size, height: size)
        guard let crop = image.cropping(to: rect),
              let ctx = CGContext(data: &px, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: size, height: size))
        var r = 0.0, g = 0.0, b = 0.0
        for i in 0..<(size * size) {
            r += Double(px[i * 4]); g += Double(px[i * 4 + 1]); b += Double(px[i * 4 + 2])
        }
        let n = Double(size * size) * 255
        let lch = OKLab.lch(fromSRGB: r / n, g / n, b / n)
        guard lch.C > 0.02 else {
            status = "色の薄い所(白・灰色・黒)なので系統は変えませんでした"
            return
        }
        selectedColorRange = ColorRange.nearest(hueDegrees: lch.h)
        status = "クリックした所の色: \(selectedColorRange.title)"
    }

    /// 色ごとの露出の段をクリック
    func pickChannel(_ row: Int, _ value: Double) {
        guard let ps = rowParams else { return }
        hoverSettings = nil
        fineTabs.insert(selectedTab)
        var s = settings
        s[keyPath: ps[row].keyPath] = ps[row].clamp(value)
        if s == settings { refreshVariations() } else { settings = s }
    }

    func hoverChannel(_ row: Int, _ value: Double, inside: Bool) {
        guard let ps = rowParams else { return }
        var s = settings
        s[keyPath: ps[row].keyPath] = value
        setHover(s, inside: inside)
    }

    func nudgeChannel(_ row: Int, _ direction: Int) {
        guard let p = rowParams?[row] else { return }
        settings[keyPath: p.keyPath] = p.clamp(settings[keyPath: p.keyPath] + Double(direction) * p.fineStep)
    }

    func channelLabel(_ row: Int) -> String {
        guard let p = rowParams?[row] else { return "" }
        return p.label(settings[keyPath: p.keyPath])
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
        if let ps = rowParams {
            var s = settings
            for p in ps { s[keyPath: p.keyPath] = 0 }
            settings = s
            return
        }
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
            decoderFailures = []
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
                // 代わりのデコーダーで開いた結果は、そのデコーダーの分としてだけ覚える
                decoderBases[b.decoderID] = b
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

    /// fallback が false なら、指定したデコーダーだけで開く(デコーダータブの比較用)
    nonisolated private static func makeBase(url: URL, decoderID: String, options: DecodeOptions,
                                             fallback: Bool = true) throws -> DecodedBase {
        let start = Date()
        var o = options
        o.halfSize = true  // プレビューは半分サイズで十分
        let decoded: DecodedImage
        if fallback {
            decoded = try DecoderRegistry.decode(url, preferred: decoderID, options: o)
        } else {
            guard let decoder = DecoderRegistry.decoder(id: decoderID) else { throw DecoderError.unsupported(url) }
            decoded = try decoder.decode(url, options: o)
        }
        guard let big = DevelopPipeline.materialize(decoded.image, maxPixel: 2400),
              let small = DevelopPipeline.materialize(big, maxPixel: 400)
        else { throw DecoderError.failed("プレビュー作成に失敗") }
        let saturation = decoded.sensorSaturation.flatMap { s -> SensorSaturationOverlay? in
            guard let cg = DevelopPipeline.context.createCGImage(s.map, from: s.map.extent) else { return nil }
            return SensorSaturationOverlay(image: cg, fraction: s.fraction, anyFraction: s.anyFraction)
        }
        return DecodedBase(decoderID: decoded.decoderID, image: big, small: small,
                           time: Date().timeIntervalSince(start), saturation: saturation, darkInfo: decoded.darkInfo)
    }

    /// 大画面を描き直す。確定済みのビットマップに当てるので速い
    func rerender() {
        renderTask?.cancel()
        guard let b = hoverDecoderID.flatMap({ decoderBases[$0] }) ?? base else { return }
        sensorSaturation = b.saturation
        darkInfo = b.darkInfo
        let box = ImageBox(image: b.image)
        let settings = hoverSettings ?? self.settings
        let clipping = showClipping
        let channel = channelView.index
        renderTask = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (CGImage, Histogram?, CGImage?)? in
                guard let cg = DevelopPipeline.renderCGImage(DevelopPipeline.apply(settings, to: box.image))
                else { return nil }
                // ヒストグラムと白飛びの判定は色付きの画像で。表示だけ 1 色の白黒にする
                let shown = channel.flatMap { Self.singleChannel(cg, $0) } ?? cg
                return (shown, Histogram.compute(from: cg),
                        clipping ? Histogram.clippingOverlay(from: cg, channel: channel) : nil)
            }.value
            guard !Task.isCancelled, let result else { return }
            preview = result.0
            histogram = result.1
            clippingOverlay = result.2
        }
        if loupeEnabled, loupePoint != nil { renderLoupe() }
    }

    /// 1 色だけを白黒で表示する画像にする(R・G・B すべてをその色の値に)
    nonisolated static func singleChannel(_ image: CGImage, _ k: Int) -> CGImage? {
        var vectors = [CIVector](repeating: CIVector(x: 0, y: 0, z: 0, w: 0), count: 3)
        let pick = CIVector(x: k == 0 ? 1 : 0, y: k == 1 ? 1 : 0, z: k == 2 ? 1 : 0, w: 0)
        vectors = vectors.map { _ in pick }
        let gray = CIImage(cgImage: image).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": vectors[0], "inputGVector": vectors[1], "inputBVector": vectors[2],
        ])
        return DevelopPipeline.renderCGImage(gray)
    }

    /// 補正前(同じデコーダーで補正をすべて 0 にしたもの)を描く
    private func renderBefore() {
        guard let b = base else { return }
        let box = ImageBox(image: b.image)
        let channel = channelView.index
        Task {
            let cg = await Task.detached(priority: .userInitiated) {
                DevelopPipeline.renderCGImage(DevelopPipeline.apply(DevelopSettings(), to: box.image))
                    .map { cg in channel.flatMap { Self.singleChannel(cg, $0) } ?? cg }
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
    /// 段階の細かさ。調整パネルを小さくしたときに増やす(1 = 標準の数、2 = 約 2 倍、3 = 約 3 倍)
    var stepDensity = 1 {
        didSet { if stepDensity != oldValue { refreshVariations() } }
    }

    /// 今のタブで使う細かさ。等倍切り出し(ノイズ低減・シャープ)は重いので増やさない
    var effectiveStepDensity: Int {
        selectedTab.param?.usesCrop == true ? 1 : stepDensity
    }

    /// 今の写真を選んだデコーダーで開けない理由(前もって分かるもの)
    var decoderUnsupportedReason: String? {
        guard let url = selectedPhoto?.url else { return nil }
        return DecoderRegistry.decoder(id: decoderID)?.unsupportedReason(url)
    }

    func refreshVariations() {
        guard !loadingVersion, base != nil else { return }
        if selectedTab == .decoder {
            loadDecoderVariations()
            return
        }
        if selectedTab.isToneEditor, let base {
            renderToneHistogram(source: base.small)
            return
        }
        if let ps = rowParams, let base {
            renderChannelRows(ps, source: base.small)
            return
        }
        if let g = selectedTab.grid, let base {
            renderGrid(g, source: base.small)
            return
        }
        guard let p = selectedTab.param, let base else { return }
        // 色味は見本を選ぶまで段階を並べない(どれも同じ絵になる)
        if selectedTab == .look && settings.lookID == nil {
            variationTask?.cancel()
            variations = []
            return
        }
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
        let d = effectiveStepDensity
        let values = fineTabs.contains(selectedTab) ? p.fineValues(around: current, density: d) : p.coarseValues(density: d)
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

    /// 色ごとの露出: R・G・B それぞれの段階を 1 段ずつ並べる
    private func renderChannelRows(_ ps: [AdjustParam], source: CIImage) {
        variationTask?.cancel()
        let settings = self.settings
        let fine = fineTabs.contains(selectedTab)
        let d = effectiveStepDensity
        let box = ImageBox(image: source)
        variationTask = Task {
            try? await Task.sleep(for: .milliseconds(20))
            guard !Task.isCancelled else { return }
            let rows = await Task.detached(priority: .userInitiated) { () -> [[Variation]] in
                ps.enumerated().map { row, p in
                    let current = settings[keyPath: p.keyPath]
                    let values = fine ? p.fineValues(around: current, density: d) : p.coarseValues(density: d)
                    return values.enumerated().compactMap { i, v in
                        var s = settings
                        s[keyPath: p.keyPath] = v
                        guard let cg = DevelopPipeline.renderCGImage(DevelopPipeline.apply(s, to: box.image)) else { return nil }
                        return Variation(id: row * 100 + i, value: v, label: p.label(v), image: cg,
                                         isCurrent: abs(v - current) < p.fineStep / 2)
                    }
                }
            }.value
            guard !Task.isCancelled else { return }
            channelVariations = rows
        }
    }

    /// ホワイトバランスのマス目: 横に色温度 9 段階、縦に色かぶり 3 段階(上がプラス)
    private func renderGrid(_ g: (x: AdjustParam, y: AdjustParam), source: CIImage) {
        variationTask?.cancel()
        let settings = self.settings
        let cx = settings[keyPath: g.x.keyPath]
        let cy = settings[keyPath: g.y.keyPath]
        let fine = fineTabs.contains(selectedTab)
        let xs = fine ? g.x.fineValues(around: cx, density: effectiveStepDensity) : g.x.coarseValues(density: effectiveStepDensity)
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

    /// フル解像度のデコード結果(等倍切り出しと虫眼鏡で共用)。同じ写真・デコーダー・設定なら使い回す
    private func fullImageBox() async -> ImageBox? {
        let key = "\(optionsKey)-\(decoderID)"
        if fullImageKey == key, let full = fullImage { return full }
        if fullImageTaskKey == key, let task = fullImageTask { return await task.value }
        guard let photo = selectedPhoto, !photo.isMissing else { return nil }
        let url = photo.url
        let id = decoderID
        var options = decodeOptions
        options.halfSize = false
        let task = Task.detached(priority: .userInitiated) { () -> ImageBox? in
            (try? DecoderRegistry.decode(url, preferred: id, options: options)).map { ImageBox(image: $0.image) }
        }
        fullImageTask = task
        fullImageTaskKey = key
        let result = await task.value
        if key == "\(optionsKey)-\(decoderID)" {
            fullImage = result
            fullImageKey = key
        }
        return result
    }

    /// 等倍切り出し用にフル解像度でデコードして、指定位置を切り出す
    private func loadCrop() {
        guard cropTask == nil, selectedPhoto != nil else { return }
        isLoadingVariations = true
        let center = cropCenter
        let key = "\(optionsKey)-\(decoderID)"
        let side = Self.cropSide

        cropTask = Task {
            let full = await fullImageBox()
            let crop = await Task.detached(priority: .userInitiated) { () -> ImageBox? in
                guard let full else { return nil }
                let e = full.image.extent
                let cx = e.minX + center.x * e.width
                let cy = e.maxY - center.y * e.height  // Core Image は左下原点
                let x = min(max(cx - side / 2, e.minX), e.maxX - side)
                let y = min(max(cy - side / 2, e.minY), e.maxY - side)
                let crop = full.image.cropped(to: CGRect(x: x, y: y, width: side, height: side).integral)
                let moved = crop.transformed(by: .init(translationX: -crop.extent.minX, y: -crop.extent.minY))
                return DevelopPipeline.materialize(moved, maxPixel: 10_000).map { ImageBox(image: $0) }
            }.value
            cropTask = nil
            isLoadingVariations = false
            guard !Task.isCancelled, let crop, key == "\(optionsKey)-\(decoderID)" else { return }
            if center == cropCenter {
                cropBase = crop
            }
            refreshVariations()
        }
    }

    // MARK: - 虫眼鏡

    /// 大画面上でマウスが動いたとき。nil で隠す
    func moveLoupe(to point: CGPoint?, pixelSize: Int) {
        guard loupeEnabled else { return }
        loupePoint = point
        loupePixelSize = pixelSize
        if point == nil {
            loupeTask?.cancel()
        } else {
            renderLoupe()
        }
    }

    /// フル解像度から、マウス位置の周りを等倍で現像して切り出す
    private func renderLoupe() {
        loupeTask?.cancel()
        guard loupeEnabled, let point = loupePoint else { return }
        let settings = hoverSettings ?? self.settings
        let size = CGFloat(loupePixelSize)
        loupeTask = Task {
            guard let full = await fullImageBox(), !Task.isCancelled else { return }
            let cg = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                let e = full.image.extent
                let cx = (e.minX + point.x * e.width).rounded()
                let cy = (e.maxY - point.y * e.height).rounded()
                let rect = CGRect(x: cx - size / 2, y: cy - size / 2, width: size, height: size)
                // ぼかし・シャープなど周りの画素を使う処理のため少し広めに現像してから切る
                let region = full.image.cropped(to: rect.insetBy(dx: -24, dy: -24))
                let out = DevelopPipeline.apply(settings, to: region)
                return DevelopPipeline.context.createCGImage(out, from: rect, format: .RGBA8,
                                                             colorSpace: CGColorSpace(name: CGColorSpace.displayP3))
            }.value
            guard !Task.isCancelled else { return }
            loupeImage = cg
        }
    }

    // MARK: - レベル補正・トーンカーブ

    private func renderToneHistogram(source: CIImage) {
        variationTask?.cancel()
        let after = settings
        var s = settings
        s.levelsBlack = 0
        s.levelsGamma = 1
        s.levelsWhite = 1
        s.curve = []
        let box = ImageBox(image: source)
        variationTask = Task {
            // 補正前(レベル補正とカーブをかける前)と補正後(すべてかけた後)
            let (h, ha) = await Task.detached(priority: .userInitiated) { () -> (Histogram?, Histogram?) in
                let before = DevelopPipeline.renderCGImage(DevelopPipeline.apply(s, to: box.image)).flatMap { Histogram.compute(from: $0) }
                let done = DevelopPipeline.renderCGImage(DevelopPipeline.apply(after, to: box.image)).flatMap { Histogram.compute(from: $0) }
                return (before, done)
            }.value
            guard !Task.isCancelled else { return }
            toneHistogram = h
            toneHistogramAfter = ha
        }
    }

    /// 輝度ヒストグラムの両端 0.1% を切って黒・白の点を決める
    func autoLevels() {
        guard let h = toneHistogram else { return }
        let counts = h.luminanceCounts
        let total = counts.reduce(0, +)
        guard total > 0 else { return }
        func percentile(_ p: Float, fromTop: Bool) -> Double {
            var acc: Float = 0
            let indices = fromTop ? Array((0..<256).reversed()) : Array(0..<256)
            for i in indices {
                acc += counts[i]
                if acc / total >= p { return Double(i) / 255 }
            }
            return fromTop ? 1 : 0
        }
        var s = settings
        s.levelsBlack = min(percentile(0.001, fromTop: false), 0.4)
        s.levelsWhite = max(percentile(0.001, fromTop: true), 0.6)
        settings = s
    }

    func resetLevels() {
        var s = settings
        s.levelsBlack = 0
        s.levelsGamma = 1
        s.levelsWhite = 1
        settings = s
    }

    func resetCurve() {
        settings.curve = []
    }

    /// 直線と同じなら空にする(保存内容を増やさない)
    func setCurve(_ points: [CurvePoint]) {
        let p = ToneCurve.normalized(points)
        let isIdentity = p.count == 2 && abs(p[0].y) < 0.001 && abs(p[1].y - 1) < 0.001
        settings.curve = isIdentity ? [] : p
    }

    /// 全デコーダーで読んで並べる(読んだものは切り替え用にも使い回す)
    private func loadDecoderVariations() {
        guard let photo = selectedPhoto, !photo.isMissing else { return }
        let missing = DecoderRegistry.all.map(\.id).filter { decoderBases[$0] == nil && !decoderFailures.contains($0) }
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
                    try? Self.makeBase(url: url, decoderID: id, options: options, fallback: false)
                }.value
                guard !Task.isCancelled, key == optionsKey else { return }
                if let b { decoderBases[id] = b } else { decoderFailures.insert(id) }
                renderDecoderVariations()
            }
            isLoadingVariations = false
        }
    }

    private func renderDecoderVariations() {
        variationTask?.cancel()
        let url = selectedPhoto?.url
        let items: [(String, String, DecodedBase?, String?)] = DecoderRegistry.all.compactMap { d in
            if let b = decoderBases[d.id] { return (d.id, d.displayName, b, nil) }
            if decoderFailures.contains(d.id) { return (d.id, d.displayName, nil, url.flatMap { d.unsupportedReason($0) }) }
            // まだ読み直していないものは、前の絵を残しておく(並びが消えたり詰まったりしないように)
            if decoderVariations.contains(where: { $0.decoderID == d.id && $0.image != nil }) {
                return (d.id, d.displayName, nil, nil)
            }
            return nil
        }
        let previous = Dictionary(decoderVariations.map { ($0.decoderID, $0) }, uniquingKeysWith: { a, _ in a })
        let failures = decoderFailures
        let settings = self.settings
        variationTask = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> [DecoderVariation] in
                items.map { id, name, b, reason in
                    if b == nil, !failures.contains(id), var old = previous[id] {
                        old.isStale = true
                        return old
                    }
                    let cg = b.flatMap { DevelopPipeline.renderCGImage(DevelopPipeline.apply(settings, to: $0.small)) }
                    return DecoderVariation(decoderID: id, name: name, time: b?.time ?? 0, image: cg, reason: reason)
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

// MARK: - 見本に合わせた色味

extension AppModel {
    /// 今の写真の色味の見本(縮小コピー)
    var lookReference: CGImage? { settings.lookID.flatMap(LookStore.reference) }
    var lookReferenceName: String? { settings.lookID.flatMap(LookStore.name) }

    func chooseLookReference() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.prompt = "見本にする"
        panel.message = "色味を近づけたい見本の写真を選んでください(JPEG・PNG・HEIC など)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setLookReference(url)
    }

    /// 見本の写真を読み、今の写真をその色味に近づける LUT を作る
    func setLookReference(_ url: URL) {
        do {
            matchLook(try ReferenceImage(url: url))
        } catch {
            status = error.localizedDescription
        }
    }

    /// 同じ見本で、今の写真(今の補正)に合わせ直す。補正を大きく変えたときや、別の写真に貼ったとき用
    func rematchLook() {
        guard let id = settings.lookID, let image = LookStore.reference(id),
              let ref = try? ReferenceImage(image: image, name: LookStore.name(id) ?? "見本") else {
            status = "見本の画像が見つかりません"
            return
        }
        matchLook(ref, keepStrength: true)
    }

    func removeLook() {
        var s = settings
        s.lookID = nil
        s.lookStrength = 100
        settings = s
    }

    private func matchLook(_ reference: ReferenceImage, keepStrength: Bool = false) {
        guard let base else { return }
        // 見本に合わせる元は、色味をかける前の今の仕上がり
        var source = settings
        source.lookID = nil
        let box = ImageBox(image: base.small)
        status = "見本「\(reference.name)」に合わせています…"
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                Result {
                    guard let cg = DevelopPipeline.renderCGImage(DevelopPipeline.apply(source, to: box.image)),
                          let samples = LookMatcher.srgbSamples(of: cg)?.1
                    else { throw DecoderError.failed("今の写真を読めません") }
                    let lut = LookMatcher.match(source: samples, reference: reference.samples)
                    return try LookStore.save(lut, reference: reference.thumbnail, name: reference.name)
                }
            }.value
            switch result {
            case .success(let id):
                var s = settings
                s.lookID = id
                if !keepStrength {
                    s.lookStrength = 100
                    fineTabs.remove(.look)
                }
                settings = s
                status = "見本「\(reference.name)」の色味にしました"
            case .failure(let error):
                status = "色味を作れません: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - 色味をほかの写真に貼る

extension AppModel {
    /// 今の写真の色味を、選んだ写真の最初のバージョンに貼る。
    /// rematch が true なら、写真ごとに RAW を読み、同じ見本でその写真に合わせた色味を作る。
    /// false なら今の色味(同じ LUT)をそのまま使う(同じ光で撮った続きの写真向け)
    func pasteLook(to photoIDs: [Int64], rematch: Bool) {
        guard let catalog, let id = settings.lookID, lookPasteProgress == nil else { return }
        flushSave()
        let strength = settings.lookStrength
        let name = LookStore.name(id) ?? "見本"
        let reference = rematch ? LookStore.reference(id).flatMap { try? ReferenceImage(image: $0, name: name) } : nil
        if rematch && reference == nil {
            status = "見本の画像が見つかりません"
            return
        }
        let targets = photos.filter { photoIDs.contains($0.id) && !$0.isMissing && $0.id != selectedPhotoID }
        guard !targets.isEmpty else { return }
        lookPasteProgress = (0, targets.count)
        Task {
            var failed: [String] = []
            for (i, photo) in targets.enumerated() {
                status = "色味を貼っています… \(i + 1) / \(targets.count)  \(photo.fileName)"
                guard var version = (try? catalog.versions(photoID: photo.id))?.first
                        ?? (try? catalog.createVersion(photoID: photo.id)) else {
                    failed.append(photo.fileName)
                    continue
                }
                var lookID = id
                if let reference {
                    let url = photo.url, decoderID = version.decoderID
                    var source = version.settings
                    source.lookID = nil
                    var options = version.decodeOptions
                    options.halfSize = true
                    let result = await Task.detached(priority: .userInitiated) { () -> String? in
                        guard let decoded = try? DecoderRegistry.decode(url, preferred: decoderID, options: options),
                              let small = DevelopPipeline.materialize(decoded.image, maxPixel: 400),
                              let cg = DevelopPipeline.renderCGImage(DevelopPipeline.apply(source, to: small)),
                              let samples = LookMatcher.srgbSamples(of: cg)?.1 else { return nil }
                        let lut = LookMatcher.match(source: samples, reference: reference.samples)
                        return try? LookStore.save(lut, reference: reference.thumbnail, name: reference.name)
                    }.value
                    guard let result else {
                        failed.append(photo.fileName)
                        lookPasteProgress = (i + 1, targets.count)
                        continue
                    }
                    lookID = result
                }
                version.settings.lookID = lookID
                version.settings.lookStrength = strength
                try? catalog.updateVersion(version)
                if let j = photos.firstIndex(where: { $0.id == photo.id }),
                   let updated = try? catalog.photo(id: photo.id) {
                    photos[j] = updated
                }
                lookPasteProgress = (i + 1, targets.count)
            }
            exportStates = (try? catalog.exportStates()) ?? [:]
            lookPasteProgress = nil
            let done = targets.count - failed.count
            status = failed.isEmpty
                ? "\(done) 枚に色味「\(name)」を貼りました"
                : "\(done) 枚に貼りました。読めなかった写真: \(failed.joined(separator: "、"))"
        }
    }
}
