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
                Section("レベル") {
                    Picker("表示する色", selection: $model.channelView) {
                        ForEach(ChannelView.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .help("R・G・B を選ぶと、大画面をその色だけの白黒で表示し、ヒストグラムと白飛びの判定もその色だけにする")
                    HistogramView(histogram: model.histogram, showClipping: $model.showClipping,
                                  channel: model.channelView,
                                  shadowRange: model.selectedTab == .shadows && model.settings.shadowRange > 0
                                      ? $model.settings.shadowRange : nil)
                    if model.selectedTab == .shadows { shadowRangeRow }
                }
                versionSection
                decoderSection
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

    /// シャドウのタブを開いている間だけ: どこまでの暗さを動かすか(ヒストグラムの左から)
    private var shadowRangeRow: some View {
        let r = model.settings.shadowRange
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("シャドウの効く範囲")
                Spacer()
                Text(r > 0 ? String(format: "左から %.0f%%", r * 100) : "以前の方式")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Picker("シャドウの効く範囲", selection: $model.settings.shadowRange) {
                ForEach(ShadowRangeChoice.all, id: \.value) { Text($0.label).tag($0.value) }
                // 選択肢にない値(ドラッグで決めた値・以前の方式)も選ばれた状態で表示できるように
                if !ShadowRangeChoice.all.contains(where: { $0.value == r }) {
                    Text(r > 0 ? String(format: "%.0f%%", r * 100) : "以前").tag(r)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(r > 0
                 ? "ヒストグラムの黄色い線より左の暗さだけが動きます。線はドラッグでも動かせます"
                 : "このバージョンは以前の方式(全体に効く)のままです。範囲を選ぶと新しい方式になります")
                .font(.caption).foregroundStyle(.secondary)
        }
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
        Section("デコード設定") {
            LabeledContent("デコーダー", value: model.displayName(for: model.decoderID))
                .help("下の「デコーダー」タブで見比べて切り替えられます")
            Picker("デモザイク", selection: $model.decodeOptions.demosaic) {
                ForEach(DemosaicMethod.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
            }
            .help("LibRaw・RawLab エンジン・RawLab ネイティブで有効(RawLab の 2 つは LINEAR = バイリニア、それ以外 = Malvar-He-Cutler)")
            .disabled(!["libraw", "rawlab", "native"].contains(model.decoderID))
            ValueSlider("デコーダー NR", value: $model.decodeOptions.noiseReduction, in: 0...1)
                .help("Core Image / LibRaw のみ有効")
            Toggle("撮影時の WB を使う", isOn: $model.decodeOptions.applyAsShotWB)
            Picker("白飛び", selection: $model.decodeOptions.highlight) {
                ForEach(HighlightMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .help("色を補って復元: 飽和していない色と周りの色合いから飽和した色を推定し、白より明るい階調も残す。下の「ハイライト圧縮」と組み合わせると、露出を下げずに雲などの階調が見える(RawLab エンジン・RawLab ネイティブ・LibRaw)")
            .disabled(!["rawlab", "native", "libraw"].contains(model.decoderID))
            if model.decodeOptions.highlight == .reconstruct, ["rawlab", "native"].contains(model.decoderID) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("復元の強さ")
                        Spacer()
                        Text("\(Int((model.decodeOptions.highlightStrength * 100).rounded()))%").monospacedDigit()
                    }
                    Slider(value: $model.decodeOptions.highlightStrength, in: 0...1, step: 0.05)
                        .controlSize(.small)
                }
                .help("0% = 切り捨てと同じ、100% = 推定した色と明るさをそのまま使う。下の「センサーの飽和」で、補っている範囲を確かめられる")
            }
            sensorSaturationRow
            darkRows
        }
    }

    /// 暗部: 黒より暗い値を残す・遮光画素で黒を測る・測ったノイズに合わせたノイズ低減
    @ViewBuilder
    private var darkRows: some View {
        let ours = ["rawlab", "native"].contains(model.decoderID)
        Toggle("黒より暗い値を残す", isOn: $model.decodeOptions.keepBelowBlack)
            .disabled(!ours)
            .help("黒レベルを引いたあとのマイナスの値(暗部のノイズの下半分)を切らずに残す。最暗部の浮きと色かぶりが減り、縮小やノイズ低減で暗部の階調が正しく平均される。夜景や高感度の、黒に近い部分が多い写真で効く(RawLab エンジン・RawLab ネイティブ)")
        VStack(alignment: .leading, spacing: 2) {
            let available = model.decoderID == "native" && model.darkInfo?.measuredBlack != nil
            Toggle("遮光画素で黒を測る", isOn: Binding(
                get: { available && model.decodeOptions.measuredBlack },
                set: { model.decodeOptions.measuredBlack = $0 }))
                .disabled(!available)
            if let d = model.darkInfo, let m = d.measuredBlack {
                Text(String(format: "黒: ファイル %.1f / 実測 %.1f  行ごとの縞 %.2f", d.declaredBlack, m, d.rowBanding ?? 0))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("RawLab ネイティブで、遮光画素を残している DNG(リコー・ペンタックスなど)だけ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .help("センサーの縁にある光の当たらない画素から、この 1 枚の本当の黒と、行ごとの黒の揺れ(横縞)を測って引く")
        VStack(alignment: .leading, spacing: 2) {
            ValueSlider("暗部のノイズ低減", value: $model.decodeOptions.shadowNoiseReduction, in: 0...1, format: "%.2f")
                .disabled(!ours)
            if let s = model.darkInfo?.noiseAtBlack {
                Text(String(format: "測ったノイズ(黒のあたり): %.3f%%", s * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .help("写真から、明るさごとのノイズの大きさを測り、まわりのばらつきがノイズ程度の所だけをなめらかにする。境目や模様は残す。暗い所ほど強く効く(RawLab エンジン・RawLab ネイティブ)")
    }

    /// センサーの飽和: 大画面に色で重ねるスイッチと、飽和した画素の割合
    private var sensorSaturationRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("センサーの飽和を表示", isOn: $model.showSensorSaturation)
                .disabled(model.sensorSaturation == nil)
            if let s = model.sensorSaturation {
                let p = { (v: Double) in v == 0 ? "0" : v < 0.001 ? "<0.1%" : String(format: "%.1f%%", v * 100) }
                Text("R \(p(s.fraction[0]))  G \(p(s.fraction[1]))  B \(p(s.fraction[2]))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("RawLab エンジン・RawLab ネイティブで表示できます")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .help("センサーがそれ以上の明るさを記録できなかった所を、飽和した色で重ねる(赤・緑・青、2 色なら黄・シアン・マゼンタ、3 色とも飽和なら白)。1 色だけの所は「色を補って復元」で戻せる。白い所は元の色がわからない")
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
