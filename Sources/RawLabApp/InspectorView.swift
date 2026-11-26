import DecoderKit
import LibraryKit
import SwiftUI

struct InspectorView: View {
    @Bindable var model: AppModel
    @State private var versionName = ""
    @State private var confirmDelete = false

    var body: some View {
        Form {
            if model.selectedPhoto != nil {
                versionSection
                decoderSection
                adjustSections
                infoSection
                exportSection
            } else {
                Text("写真を選んでください").foregroundStyle(.secondary)
            }
            if !model.status.isEmpty {
                Section {
                    Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.currentVersionID, initial: true) { versionName = model.currentVersion?.name ?? "" }
        .onChange(of: model.currentVersion?.name) { versionName = model.currentVersion?.name ?? "" }
    }

    private var versionSection: some View {
        Section("現像バージョン") {
            Picker("バージョン", selection: $model.currentVersionID) {
                ForEach(model.versions) { Text($0.name).tag(Optional($0.id)) }
            }
            TextField("名前", text: $versionName)
                .onSubmit { model.renameCurrentVersion(versionName) }
            HStack {
                Button("複製") { model.duplicateVersion() }
                    .help("今の設定をコピーして新しいバージョンを作る")
                Button("新規") { model.newVersion() }
                    .help("初期設定で新しいバージョンを作る")
                Spacer()
                Button("削除…", role: .destructive) { confirmDelete = true }
                    .disabled(model.versions.count <= 1)
            }
            .confirmationDialog("「\(model.currentVersion?.name ?? "")」を削除しますか?", isPresented: $confirmDelete) {
                Button("削除", role: .destructive) { model.deleteCurrentVersion() }
            } message: {
                Text("このバージョンの現像設定と書き出し履歴が削除されます。書き出したファイルは残ります。")
            }
        }
    }

    private var decoderSection: some View {
        Group {
            Section("デコーダー") {
                Picker("デコーダー", selection: $model.decoderID) {
                    ForEach(DecoderRegistry.all, id: \.id) { Text($0.displayName).tag($0.id) }
                }
                Picker("デモザイク", selection: $model.decodeOptions.demosaic) {
                    ForEach(DemosaicMethod.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                }
                .help("LibRaw のみ有効")
                .disabled(model.decoderID != "libraw" && !(model.compareEnabled && model.compareDecoderID == "libraw"))
                ValueSlider("デコーダー NR", value: $model.decodeOptions.noiseReduction, in: 0...1)
                    .help("Core Image / LibRaw のみ有効")
                Toggle("撮影時の WB を使う", isOn: $model.decodeOptions.applyAsShotWB)
            }
            Section("比較") {
                Toggle("2 つのデコーダーを並べる", isOn: $model.compareEnabled)
                if model.compareEnabled {
                    Picker("比較相手", selection: $model.compareDecoderID) {
                        ForEach(DecoderRegistry.all, id: \.id) { Text($0.displayName).tag($0.id) }
                    }
                }
            }
        }
    }

    private var adjustSections: some View {
        Group {
            Section("基本補正") {
                ValueSlider("露出", value: $model.settings.exposure, in: -3...3, format: "%+.2f EV")
                ValueSlider("色温度", value: $model.settings.temperature, in: -2000...2000, format: "%+.0f K")
                ValueSlider("色かぶり", value: $model.settings.tint, in: -100...100, format: "%+.0f")
                ValueSlider("コントラスト", value: $model.settings.contrast, in: -1...1)
                ValueSlider("ハイライト復元", value: $model.settings.highlights, in: 0...1)
                ValueSlider("シャドウ", value: $model.settings.shadows, in: -1...1)
                ValueSlider("自然な彩度", value: $model.settings.vibrance, in: -1...1)
                ValueSlider("彩度", value: $model.settings.saturation, in: -1...1)
            }
            Section("ディテール") {
                ValueSlider("ノイズ低減", value: $model.settings.noiseReduction, in: 0...1)
                ValueSlider("シャープ", value: $model.settings.sharpness, in: 0...1)
                Button("補正をリセット") { model.resetSettings() }
            }
        }
    }

    @ViewBuilder
    private var infoSection: some View {
        if let photo = model.selectedPhoto {
            Section("情報") {
                if let m = photo.metadata {
                    LabeledContent("カメラ", value: "\(m.make) \(m.model)")
                    if !m.lens.isEmpty { LabeledContent("レンズ", value: m.lens) }
                    LabeledContent("露出", value: "ISO \(Int(m.iso))  \(m.shutterString)  f/\(String(format: "%.1f", m.aperture))")
                    LabeledContent("焦点距離", value: "\(Int(m.focalLength)) mm")
                    if let pc = m.pictureControl { LabeledContent("ピクチャーコントロール", value: pc) }
                    if let adl = m.activeDLighting { LabeledContent("アクティブD-ライティング", value: adl) }
                }
                if let date = photo.captureDate {
                    LabeledContent("撮影日時", value: date.formatted(date: .numeric, time: .standard))
                }
                LabeledContent("RAW") {
                    Button(photo.url.deletingLastPathComponent().lastPathComponent + "/" + photo.fileName) {
                        model.revealInFinder(photo.url)
                    }
                    .buttonStyle(.link)
                    .help(photo.path)
                    .disabled(photo.isMissing)
                }
            }
        }
    }

    private var exportSection: some View {
        Section("書き出し") {
            LabeledContent("書き出し先") {
                Button((model.exportRoot.path as NSString).abbreviatingWithTildeInPath) { model.chooseExportRoot() }
                    .buttonStyle(.link)
                    .help("クリックで変更。中は撮影日ごとのフォルダに分かれます")
            }
            Picker("形式", selection: $model.exportFormat) {
                ForEach(ExportFormat.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
            }
            if let last = model.lastExport {
                LabeledContent("前回") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Button(last.url.lastPathComponent) { model.revealInFinder(last.url) }
                            .buttonStyle(.link)
                            .help(last.path)
                        Text(last.exportedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.currentNeedsReexport {
                    Label("前回の書き出し後に変更あり", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                }
            }
            HStack {
                Spacer()
                if model.isExporting { ProgressView().controlSize(.small) }
                Button(model.lastExport == nil ? "書き出し" : "再書き出し") { model.export() }
                    .keyboardShortcut("e")
                    .disabled(model.isExporting || (model.selectedPhoto?.isMissing ?? true))
            }
        }
    }
}

/// ラベル + 値 + スライダー。ダブルクリックで 0 に戻す
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, format: String = "%+.2f") {
        self.title = title
        self._value = value
        self.range = range
        self.format = format
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value))
                    .monospacedDigit()
                    .foregroundStyle(value == 0 ? .secondary : .primary)
            }
            Slider(value: $value, in: range)
                .controlSize(.small)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { value = 0 }
    }
}
