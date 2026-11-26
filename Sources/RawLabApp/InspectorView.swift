import DecoderKit
import SwiftUI

struct InspectorView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
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
            }

            if let m = model.metadata {
                Section("情報") {
                    LabeledContent("カメラ", value: "\(m.make) \(m.model)")
                    if !m.lens.isEmpty { LabeledContent("レンズ", value: m.lens) }
                    LabeledContent("露出", value: "ISO \(Int(m.iso))  \(m.shutterString)  f/\(String(format: "%.1f", m.aperture))")
                    LabeledContent("焦点距離", value: "\(Int(m.focalLength)) mm")
                    if let pc = m.pictureControl { LabeledContent("ピクチャーコントロール", value: pc) }
                    if let adl = m.activeDLighting { LabeledContent("アクティブD-ライティング", value: adl) }
                }
            }

            Section("書き出し") {
                Picker("形式", selection: $model.exportFormat) {
                    ForEach(ExportFormat.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                }
                HStack {
                    Button("書き出し…") { model.export() }
                    Spacer()
                    Button("補正をリセット") { model.resetSettings() }
                }
                if !model.status.isEmpty {
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
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
