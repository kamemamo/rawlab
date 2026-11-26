import DecoderKit
import SwiftUI

/// 大画面の下のパネル: 項目タブ + 段階サムネイル + 微調整
struct AdjustPanel: View {
    @Bindable var model: AppModel
    @FocusState private var focused: Bool

    private let panelBackground = Color(white: 0.17)
    private let accent = Color(red: 0.31, green: 0.63, blue: 1.0)

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Group {
                if model.selectedTab == .decoder {
                    decoderStrip
                } else if model.selectedTab.grid != nil {
                    wbGrid
                } else {
                    variationStrip
                }
            }
            .frame(height: model.selectedTab.grid != nil ? 300 : 132)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            controls
        }
        .background(panelBackground)
        .foregroundStyle(.white)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow) { model.nudge(-1); return .handled }
        .onKeyPress(.rightArrow) { model.nudge(1); return .handled }
        .onKeyPress(.upArrow) {
            guard model.selectedTab.grid != nil else { return .ignored }
            model.nudgeVertical(1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard model.selectedTab.grid != nil else { return .ignored }
            model.nudgeVertical(-1)
            return .handled
        }
    }

    // MARK: タブ

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(AdjustTab.allCases) { tab in
                    Button {
                        model.selectedTab = tab
                        focused = true
                    } label: {
                        Text(tab.title)
                            .font(.callout)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .foregroundStyle(model.selectedTab == tab ? .white : .white.opacity(0.6))
                            .background(model.selectedTab == tab ? Color.white.opacity(0.14) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    if tab == .sharpness { Divider().frame(height: 16).padding(.horizontal, 4) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
        }
    }

    // MARK: 段階サムネイル

    @Environment(\.displayScale) private var displayScale

    @ViewBuilder
    private var variationStrip: some View {
        if model.selectedTab.param?.usesCrop == true {
            // 等倍: 画面のピクセルと 1:1 になる大きさに固定し、はみ出たら横スクロール
            ScrollView(.horizontal, showsIndicators: true) {
                variationItems(cropPoints: AppModel.cropSide / max(displayScale, 1))
            }
            .frame(maxWidth: .infinity)
            .overlay {
                if model.variations.isEmpty || model.isLoadingVariations {
                    ProgressView("等倍で読み込み中…").controlSize(.small)
                }
            }
        } else {
            variationItems(cropPoints: nil)
        }
    }

    private func variationItems(cropPoints: CGFloat?) -> some View {
        HStack(spacing: 0) {
            ForEach(model.variations) { v in
                VStack(spacing: 3) {
                    Image(decorative: v.image, scale: 1)
                        .resizable()
                        .interpolation(cropPoints != nil ? .none : .high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: cropPoints, height: cropPoints)
                        .frame(maxWidth: cropPoints == nil ? .infinity : nil,
                               maxHeight: cropPoints == nil ? .infinity : nil)
                        .overlay {
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(v.isCurrent ? accent : .clear, lineWidth: 2)
                        }
                    Text(v.label)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(v.isCurrent ? accent : .white.opacity(0.7))
                }
                .padding(2)  // 見た目の隙間は内側に取り、マウスが外れる場所を作らない
                .contentShape(Rectangle())
                .onTapGesture {
                    model.pick(v.value)
                    focused = true
                }
                .onHover { inside in model.hover(v.value, inside: inside) }
            }
        }
        .overlay {
            if model.variations.isEmpty || model.isLoadingVariations {
                ProgressView().controlSize(.small)
            }
        }
    }

    /// ホワイトバランス: 横に色温度、縦に色かぶり
    private var wbGrid: some View {
        let g = model.selectedTab.grid!
        let cols = model.gridColumns
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("色かぶり").font(.caption2).foregroundStyle(.white.opacity(0.5)).frame(width: 44)
                ForEach(Array(cols.enumerated()), id: \.offset) { _, x in
                    Text(g.x.label(x))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(Array(model.gridRows.enumerated()), id: \.offset) { row, y in
                HStack(spacing: 0) {
                    Text(g.y.label(y))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 44)
                    ForEach(model.gridVariations.filter { $0.id / max(cols.count, 1) == row }) { v in
                        Image(decorative: v.image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay {
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(v.isCurrent ? accent : .clear, lineWidth: 2)
                            }
                            .padding(2)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.pickGrid(x: v.x, y: v.y)
                                focused = true
                            }
                            .onHover { inside in model.hoverGrid(x: v.x, y: v.y, inside: inside) }
                    }
                }
            }
        }
        .overlay {
            if model.gridVariations.isEmpty { ProgressView().controlSize(.small) }
        }
    }

    private var decoderStrip: some View {
        HStack(spacing: 0) {
            ForEach(model.decoderVariations) { d in
                VStack(spacing: 3) {
                    Image(decorative: d.image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: .infinity)
                        .overlay {
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(d.decoderID == model.decoderID ? accent : .clear, lineWidth: 2)
                        }
                    Text("\(d.name)  ·  \(String(format: "%.2fs", d.time))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(d.decoderID == model.decoderID ? accent : .white.opacity(0.7))
                }
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
                .onTapGesture { model.pickDecoder(d.decoderID) }
                .onHover { inside in model.hoverDecoder(d.decoderID, inside: inside) }
            }
            if model.isLoadingVariations {
                ProgressView().controlSize(.small).padding(.horizontal, 20)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: 微調整

    private var controls: some View {
        HStack(spacing: 10) {
            if let g = model.selectedTab.grid {
                Text("色温度").foregroundStyle(.white.opacity(0.7))
                Button { model.nudge(-1) } label: { Image(systemName: "minus") }.help("←キーでも動かせます")
                Text(model.gridLabel(\.x)).font(.body.monospacedDigit()).frame(minWidth: 70)
                Button { model.nudge(1) } label: { Image(systemName: "plus") }.help("→キーでも動かせます")
                Text("色かぶり").foregroundStyle(.white.opacity(0.7))
                Button { model.nudgeVertical(-1) } label: { Image(systemName: "minus") }.help("↓キーでも動かせます")
                Text(model.gridLabel(\.y)).font(.body.monospacedDigit()).frame(minWidth: 40)
                Button { model.nudgeVertical(1) } label: { Image(systemName: "plus") }.help("↑キーでも動かせます")
                let fine = model.fineTabs.contains(model.selectedTab)
                Button(fine ? "粗く選び直す" : "細かく") { model.toggleFine() }
                Text(fine ? "細かい段階(\(g.x.label(g.x.fineStep)) / \(g.y.label(g.y.fineStep)) 刻み)" : "粗い段階")
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
                Button("0 に戻す") { model.resetCurrentParam() }
                Text("色温度 + で暖かく、色かぶり + でマゼンタ寄り")
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
            } else if let p = model.selectedTab.param {
                Text(model.selectedTab.title).foregroundStyle(.white.opacity(0.7))
                Button { model.nudge(-1) } label: { Image(systemName: "minus") }
                    .help("←キーでも動かせます")
                Text(model.currentParamLabel)
                    .font(.body.monospacedDigit())
                    .frame(minWidth: 80)
                Button { model.nudge(1) } label: { Image(systemName: "plus") }
                    .help("→キーでも動かせます")
                let fine = model.fineTabs.contains(model.selectedTab)
                Button(fine ? "粗く選び直す" : "細かく") { model.toggleFine() }
                Text(fine ? "細かい段階(\(p.label(p.fineStep)) 刻み)" : "粗い段階")
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
                Button("0 に戻す") { model.resetCurrentParam() }
                if p.usesCrop {
                    Text("大きな画面をクリックすると等倍で見る場所を変えられます")
                        .font(.caption).foregroundStyle(.white.opacity(0.5))
                }
            } else {
                Text("クリックでデコーダーを切り替え。マウスを乗せると上の画面で確認できます")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Button("すべての補正をリセット") { model.resetSettings() }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// 中央の大きな画面
struct PreviewArea: View {
    let model: AppModel

    var body: some View {
        ZStack {
            Color(white: 0.12)
            if let photo = model.selectedPhoto, photo.isMissing {
                ContentUnavailableView {
                    Label("RAW が見つかりません", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("元の場所: \(photo.path)\nフォルダを戻すか、移動先のフォルダをライブラリに追加して再スキャンすると、現像データを引き継いでつなぎ直します。")
                }
                .foregroundStyle(.white)
            } else if let image = model.preview {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .overlay { cropOverlay }
                    .padding(12)
            } else if model.isDecoding {
                ProgressView("デコード中…").controlSize(.large).foregroundStyle(.white)
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.isDecoding && model.preview != nil {
                ProgressView().controlSize(.small).padding(16)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let id = model.previewDecoderID, id != model.decoderID {
                Text("\(model.displayName(for: model.decoderID)) で開けなかったため \(model.displayName(for: id)) で表示中")
                    .font(.caption).foregroundStyle(.orange).padding(16)
            }
        }
    }

    /// ノイズ低減・シャープのタブでは、等倍で切り出す場所を枠で示し、クリックで移動
    @ViewBuilder
    private var cropOverlay: some View {
        if model.selectedTab.param?.usesCrop == true {
            GeometryReader { geo in
                let side = geo.size.width * model.cropFraction
                ZStack {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            model.setCropCenter(CGPoint(x: location.x / geo.size.width,
                                                        y: location.y / geo.size.height))
                        }
                    Rectangle()
                        .stroke(Color.yellow, lineWidth: 1.5)
                        .frame(width: max(side, 8), height: max(side, 8))
                        .position(x: model.cropCenter.x * geo.size.width, y: model.cropCenter.y * geo.size.height)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}
