import DecoderKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showInspector = true

    var body: some View {
        NavigationSplitView {
            List(model.files, id: \.self, selection: $model.selection) { url in
                ThumbnailRow(url: url, image: model.thumbnails[url])
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 210)
            .overlay {
                if model.files.isEmpty {
                    ContentUnavailableView {
                        Label("RAW がありません", systemImage: "camera.aperture")
                    } actions: {
                        Button("フォルダを開く…") { model.openFolder() }
                    }
                }
            }
        } detail: {
            PreviewArea(model: model)
                .inspector(isPresented: $showInspector) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
                }
        }
        .navigationTitle(model.selection?.lastPathComponent ?? "RawLab")
        .navigationSubtitle(model.metadata?.summary ?? "")
        .toolbar {
            ToolbarItemGroup {
                Button { model.openFolder() } label: { Label("フォルダを開く", systemImage: "folder") }
                Toggle(isOn: $model.compareEnabled) { Label("比較", systemImage: "rectangle.split.2x1") }
                Button { model.export() } label: { Label("書き出し", systemImage: "square.and.arrow.up") }
                    .disabled(model.selection == nil)
                Button { showInspector.toggle() } label: { Label("調整", systemImage: "slider.horizontal.3") }
            }
        }
    }
}

struct ThumbnailRow: View {
    let url: URL
    let image: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                } else {
                    Rectangle().fill(.quaternary).aspectRatio(1.5, contentMode: .fit)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(url.lastPathComponent).font(.caption).lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}

struct PreviewArea: View {
    let model: AppModel

    var body: some View {
        ZStack {
            Color(white: 0.12).ignoresSafeArea()
            if model.previews.isEmpty {
                if model.isDecoding {
                    ProgressView("デコード中…").controlSize(.large).foregroundStyle(.white)
                } else if !model.status.isEmpty {
                    Text(model.status).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(Array(model.previews.enumerated()), id: \.offset) { _, preview in
                        VStack(spacing: 6) {
                            Image(decorative: preview.image, scale: 1)
                                .resizable()
                                .scaledToFit()
                            if model.previews.count > 1 || preview.decoderID != model.decoderID {
                                Text("\(model.displayName(for: preview.decoderID))  ·  \(String(format: "%.2fs", preview.time))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                        }
                    }
                }
                .padding(12)
                .overlay(alignment: .topTrailing) {
                    if model.isDecoding { ProgressView().controlSize(.small).padding(16) }
                }
            }
        }
    }
}
