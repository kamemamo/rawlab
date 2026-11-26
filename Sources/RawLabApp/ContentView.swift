import DecoderKit
import LibraryKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showInspector = true
    @State private var folderToRemove: LibraryFolder?

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            photoList
        } detail: {
            VStack(spacing: 0) {
                PreviewArea(model: model)
                AdjustPanel(model: model)
            }
                .inspector(isPresented: $showInspector) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
                }
        }
        .navigationTitle(model.selectedPhoto?.fileName ?? "RawLab")
        .navigationSubtitle(model.selectedPhoto?.metadata?.summary ?? "")
        .toolbar {
            ToolbarItem {
                Picker("比較", selection: $model.compareMode) {
                    Text("補正前").tag(CompareMode.before)
                    Text("補正後").tag(CompareMode.off)
                    Text("左右で比較").tag(CompareMode.split)
                }
                .pickerStyle(.segmented)
                .help("補正前(同じデコーダーで補正をすべて 0 にしたもの)と見比べる")
            }
            ToolbarItemGroup {
                Toggle(isOn: $model.loupeEnabled) { Label("虫眼鏡", systemImage: "magnifyingglass") }
                    .help("大画面の上でマウスの周りを等倍(100%)で拡大")
                Button { model.export() } label: { Label("書き出し", systemImage: "square.and.arrow.up") }
                    .disabled(model.selectedPhoto?.isMissing ?? true)
                Button { showInspector.toggle() } label: { Label("調整", systemImage: "slider.horizontal.3") }
            }
        }
        .confirmationDialog(
            "「\(folderToRemove?.name ?? "")」をライブラリから外しますか?",
            isPresented: Binding(get: { folderToRemove != nil }, set: { if !$0 { folderToRemove = nil } }),
            presenting: folderToRemove
        ) { folder in
            Button("ライブラリから外す", role: .destructive) { model.removeFolder(folder) }
        } message: { _ in
            Text("RAW ファイルと書き出したファイルはそのまま残りますが、このフォルダの写真の現像データと書き出し履歴は削除されます。")
        }
    }

    private var sidebar: some View {
        List(selection: $model.sidebarSelection) {
            Label("すべての写真", systemImage: "photo.on.rectangle").tag(SidebarItem.all)
            Section("フォルダ") {
                ForEach(model.folders) { folder in
                    HStack {
                        Label(folder.name, systemImage: folder.isAvailable ? "folder" : "externaldrive.badge.xmark")
                            .help(folder.path)
                        Spacer()
                        Text("\(model.folderCounts[folder.id] ?? 0)").foregroundStyle(.secondary).monospacedDigit()
                    }
                    .tag(SidebarItem.folder(folder.id))
                    .contextMenu {
                        Button("Finder で表示") { model.revealInFinder(folder.url) }
                        Button("ライブラリから外す…") { folderToRemove = folder }
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 120, ideal: 150, max: 240)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { model.addFolder() } label: { Label("フォルダを追加", systemImage: "plus") }
                Spacer()
                Button { model.rescanAll() } label: { Image(systemName: "arrow.clockwise") }
                    .help("すべてのフォルダを再スキャン")
                    .disabled(model.isScanning)
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
    }

    private var photoList: some View {
        List(model.photos, selection: $model.selectedPhotoID) { photo in
            PhotoRow(photo: photo, image: model.thumbnails[photo.id], state: model.exportStates[photo.id])
                .task(id: photo.id) { await model.loadThumbnail(for: photo) }
        }
        .navigationSplitViewColumnWidth(min: 100, ideal: 130, max: 260)
        .overlay {
            if model.photos.isEmpty {
                if model.isScanning {
                    ProgressView("スキャン中…")
                } else {
                    ContentUnavailableView {
                        Label("写真がありません", systemImage: "camera.aperture")
                    } description: {
                        Text("RAW の入ったフォルダをライブラリに追加してください")
                    } actions: {
                        Button("フォルダを追加…") { model.addFolder() }
                    }
                }
            }
        }
    }
}

struct PhotoRow: View {
    let photo: Photo
    let image: CGImage?
    let state: ExportState?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image {
                        Image(decorative: image, scale: 1).resizable().scaledToFit()
                    } else {
                        Rectangle().fill(.quaternary).aspectRatio(1.5, contentMode: .fit)
                            .overlay {
                                if photo.isMissing {
                                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                                }
                            }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .opacity(photo.isMissing ? 0.5 : 1)

                HStack(spacing: 3) {
                    if photo.versionCount > 1 {
                        Badge(text: "\(photo.versionCount)", systemImage: "square.stack")
                    }
                    switch state {
                    case .needsReexport: Badge(systemImage: "arrow.triangle.2.circlepath", tint: .orange)
                    case .upToDate: Badge(systemImage: "checkmark", tint: .green)
                    default: EmptyView()
                    }
                }
                .padding(4)
            }
            HStack(spacing: 4) {
                if photo.isMissing {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Text(photo.fileName).font(.caption).lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .help(photo.isMissing ? "見つかりません: \(photo.path)" : photo.path)
    }
}

private struct Badge: View {
    var text: String? = nil
    let systemImage: String
    var tint: Color = .black

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: systemImage)
            if let text { Text(text) }
        }
        .font(.caption2.bold())
        .foregroundStyle(.white)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(tint.opacity(0.75), in: Capsule())
    }
}
