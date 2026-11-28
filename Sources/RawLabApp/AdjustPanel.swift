import AppKit
import DecoderKit
import SwiftUI

/// 大画面の下のパネル: 項目タブ + 段階サムネイル + 微調整
struct AdjustPanel: View {
    @Bindable var model: AppModel
    @FocusState private var focused: Bool
    @State private var lookDropTargeted = false
    /// 段階サムネイルの段の高さの倍率(上の縁をドラッグで変える。ダブルクリックで元に戻す)
    @AppStorage("adjustPanelScale") private var panelScale = 1.0
    @State private var dragStartScale: Double?
    private static let scaleRange = 0.5...3.0

    private let panelBackground = Color(white: 0.17)
    private let accent = Color(red: 0.31, green: 0.63, blue: 1.0)

    var body: some View {
        VStack(spacing: 0) {
            resizeHandle
            tabBar
            Group {
                if model.selectedTab == .decoder {
                    decoderStrip
                } else if model.selectedTab.grid != nil {
                    wbGrid
                } else if model.selectedTab == .hsl {
                    VStack(spacing: 6) {
                        colorChips
                        channelRows
                    }
                } else if model.rowParams != nil {
                    channelRows
                } else if model.selectedTab == .tone {
                    // レベル補正とトーンカーブを 1 つのグラフで(三角はグラフの横軸の真下)
                    CurveEditor(model: model)
                } else if model.selectedTab == .look {
                    lookStrip
                } else {
                    variationStrip
                }
            }
            .frame(height: stripHeight)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            controls
        }
        .background(panelBackground)
        .foregroundStyle(.white)
        .sheet(isPresented: $model.isLookPasteSheetShown) { LookPasteSheet(model: model) }
        .onChange(of: panelScale, initial: true) { _, scale in
            // 小さくするほど段階を増やし、全体を俯瞰できるようにする
            model.stepDensity = scale < 0.6 ? 3 : scale < 0.8 ? 2 : 1
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow) { model.nudge(-1); return .handled }
        .onKeyPress(.rightArrow) { model.nudge(1); return .handled }
        .onKeyPress(.escape) {
            guard model.isEyedropperActive else { return .ignored }
            model.isEyedropperActive = false
            return .handled
        }
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

    // MARK: 大きさ

    /// 項目ごとの標準の高さ。トーンのグラフは大きさを変えない
    private var baseHeight: Double {
        model.selectedTab == .hsl ? 236
            : model.selectedTab.grid != nil || model.rowParams != nil ? 200
            : model.selectedTab.isToneEditor ? 250 : 132
    }

    private var stripHeight: Double {
        model.selectedTab.isToneEditor ? baseHeight : min(baseHeight * panelScale, 620)
    }

    /// パネルの上の縁。上へドラッグでサムネイルが大きく、下へで小さく(そのぶん大画面が広がる)
    private var resizeHandle: some View {
        ZStack {
            Color.white.opacity(0.001)
            Capsule()
                .fill(Color.white.opacity(dragStartScale != nil ? 0.6 : 0.25))
                .frame(width: 36, height: 4)
        }
        .frame(height: 10)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    let start = dragStartScale ?? panelScale
                    if dragStartScale == nil { dragStartScale = start }
                    let height = baseHeight * start - v.translation.height
                    panelScale = min(max(height / baseHeight, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
                }
                .onEnded { _ in dragStartScale = nil }
        )
        .onTapGesture(count: 2) { panelScale = 1 }
        .help("ドラッグでサムネイルの大きさを変えます(ダブルクリックで元の大きさ)")
    }

    /// 段階を増やしたときは隙間をなくす
    private var itemPadding: CGFloat { model.effectiveStepDensity > 1 ? 0.5 : 2 }

    /// 段階を増やしたときは数字が重なるので、もとの段階の位置と今の値だけに数字を出す
    private func showsLabel(_ index: Int, current: Bool) -> Bool {
        current || index % model.effectiveStepDensity == 0
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
                    // デコーダー(RAW の読み込み方)と補正の項目の間に区切り
                    if tab == .decoder { Divider().frame(height: 16).padding(.horizontal, 4) }
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
                    Text(showsLabel(v.id, current: v.isCurrent) ? v.label : " ")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(v.isCurrent ? accent : .white.opacity(0.7))
                        .lineLimit(1)
                        .fixedSize()
                        .frame(maxWidth: cropPoints == nil ? 0 : nil)
                }
                .padding(itemPadding)  // 見た目の隙間は内側に取り、マウスが外れる場所を作らない
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

    // MARK: 色味(見本に合わせる)

    /// 左に見本、右に強さの段階。見本の写真はこの枠のどこにドロップしてもよい
    private var lookStrip: some View {
        HStack(spacing: 10) {
            VStack(spacing: 3) {
                Group {
                    if let ref = model.lookReference {
                        Image(decorative: ref, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            .foregroundStyle(.white.opacity(0.4))
                            .overlay {
                                VStack(spacing: 4) {
                                    Image(systemName: "photo.on.rectangle.angled").font(.title2)
                                    Text("見本をドロップ").font(.caption)
                                }
                                .foregroundStyle(.white.opacity(0.6))
                            }
                    }
                }
                .frame(width: 150)
                .frame(maxHeight: .infinity)
                Text(model.lookReferenceName.map { "見本: \($0)" } ?? "見本なし")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 150)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.chooseLookReference() }
            .help("クリックで見本の写真を選びます")
            Divider()
            if model.settings.lookID != nil {
                variationStrip
            } else {
                VStack(spacing: 6) {
                    Text("見本の写真の色味に、この写真を近づけます")
                    Text("JPEG・PNG・HEIC などをここにドロップするか、「見本を選ぶ…」を押してください。\n明るさの分布と、暗部・中間・明部それぞれの色の傾きを見本に合わせます(被写体の色まで写さないよう控えめにかけます)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(4)
        .overlay {
            if lookDropTargeted {
                RoundedRectangle(cornerRadius: 6).stroke(accent, lineWidth: 2)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.setLookReference(url)
            return true
        } isTargeted: { lookDropTargeted = $0 }
    }

    /// 色ごとの露出: R・G・B の 3 段。それぞれの段で独立に選ぶ
    /// 色ごとの調整: 8 系統の選択
    private var colorChips: some View {
        HStack(spacing: 4) {
            ForEach(ColorRange.allCases) { r in
                let sw = r.swatch
                let selected = model.selectedColorRange == r
                Button {
                    model.selectedColorRange = r
                    focused = true
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color(red: sw.r, green: sw.g, blue: sw.b))
                            .frame(width: 12, height: 12)
                        Text(r.title).font(.caption)
                        if !model.settings.colorAdjustments[r].isZero {
                            Circle().fill(accent).frame(width: 5, height: 5)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(selected ? Color.white.opacity(0.18) : Color.white.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? accent : .clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private var channelRows: some View {
        let hsl = model.selectedTab == .hsl
        let colors: [Color] = hsl ? [.white, .white, .white] : [.red, .green, .blue]
        return VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 0) {
                    Text(model.rowTitles[row])
                        .font(hsl ? .caption.bold() : .callout.bold())
                        .foregroundStyle(colors[row].opacity(hsl ? 0.8 : 1))
                        .frame(width: hsl ? 36 : 30)
                    ForEach(model.channelVariations[row]) { v in
                        VStack(spacing: 1) {
                            Image(decorative: v.image, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(v.isCurrent ? accent : .clear, lineWidth: 2)
                                }
                            Text(showsLabel(v.id % 100, current: v.isCurrent) ? v.label : " ")
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(v.isCurrent ? accent : .white.opacity(0.6))
                                .lineLimit(1)
                                .fixedSize()
                                .frame(maxWidth: 0)
                        }
                        .padding(itemPadding)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.pickChannel(row, v.value)
                            focused = true
                        }
                        .onHover { inside in model.hoverChannel(row, v.value, inside: inside) }
                    }
                }
            }
        }
        .overlay {
            if model.channelVariations.allSatisfy(\.isEmpty) { ProgressView().controlSize(.small) }
        }
    }

    /// ホワイトバランス: 横に色温度、縦に色かぶり
    private var wbGrid: some View {
        let g = model.selectedTab.grid!
        let cols = model.gridColumns
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("色かぶり").font(.caption2).foregroundStyle(.white.opacity(0.5)).frame(width: 44)
                ForEach(Array(cols.enumerated()), id: \.offset) { i, x in
                    Text(showsLabel(i, current: false) ? g.x.label(x) : " ")
                        .lineLimit(1)
                        .fixedSize()
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
                            .padding(itemPadding)
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
                    if let image = d.image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: .infinity)
                            .overlay {
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(d.decoderID == model.decoderID ? accent : .clear, lineWidth: 2)
                            }
                    } else {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white.opacity(0.06))
                            .aspectRatio(1.5, contentMode: .fit)
                            .frame(maxHeight: .infinity)
                            .overlay {
                                Text(d.reason.map { "このデコーダーは\n\($0)" } ?? "このデコーダーでは\n開けません")
                                    .font(.caption).multilineTextAlignment(.center)
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                    }
                    Text(d.image == nil ? d.name : "\(d.name)  ·  \(String(format: "%.2fs", d.time))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(d.decoderID == model.decoderID ? accent : .white.opacity(d.image == nil ? 0.4 : 0.7))
                }
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
                .onTapGesture { if d.image != nil { model.pickDecoder(d.decoderID) } }
                .onHover { inside in if d.image != nil { model.hoverDecoder(d.decoderID, inside: inside) } }
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
            if model.rowParams != nil {
                let hsl = model.selectedTab == .hsl
                if hsl {
                    Text(model.selectedColorRange.title).bold()
                }
                ForEach(0..<3, id: \.self) { row in
                    Text(model.rowTitles[row])
                        .foregroundStyle(hsl ? Color.white.opacity(0.7) : [Color.red, .green, .blue][row])
                    Button { model.nudgeChannel(row, -1) } label: { Image(systemName: "minus") }
                    Text(model.channelLabel(row)).font(.body.monospacedDigit()).frame(minWidth: 44)
                    Button { model.nudgeChannel(row, 1) } label: { Image(systemName: "plus") }
                }
                let fine = model.fineTabs.contains(model.selectedTab)
                Button(fine ? "粗く選び直す" : "細かく") { model.toggleFine() }
                Button(hsl ? "この色を 0 に" : "0 に戻す") { model.resetCurrentParam() }
                    .help(hsl ? "選んでいる系統の 色相・彩度・明度 を 0 に戻す" : "R・G・B すべてを 0 に戻す(単位は EV)")
                if hsl {
                    Button("全色を 0 に") { model.resetAllColors() }
                    Text("大画面をクリックすると、その色の系統を選びます")
                        .font(.caption).foregroundStyle(.white.opacity(0.5))
                }
            } else if let g = model.selectedTab.grid {
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
                Button {
                    model.isEyedropperActive.toggle()
                    focused = true
                } label: {
                    Label(model.isEyedropperActive ? "スポイト中" : "スポイト", systemImage: "eyedropper")
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(model.isEyedropperActive ? accent : Color.white.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("押してから、大きな画面の白やグレーの部分をクリック(esc で中止)。色温度 + で暖かく、色かぶり + でマゼンタ寄り")
            } else if model.selectedTab == .tone {
                let s = model.settings
                Text(String(format: "黒 %d   中間 %.2f   白 %d",
                            Int(s.levelsBlack * 255), s.levelsGamma, Int(s.levelsWhite * 255)))
                    .font(.body.monospacedDigit())
                Button("自動") { model.autoLevels() }
                    .help("明るさの分布の両端 0.1% を切って黒と白の点を決めます")
                Button("レベルをリセット") { model.resetLevels() }
                Button("カーブをリセット") { model.resetCurve() }
            } else if model.selectedTab == .look {
                Button("見本を選ぶ…") { model.chooseLookReference() }
                if let p = model.selectedTab.param, model.settings.lookID != nil {
                    Text("強さ").foregroundStyle(.white.opacity(0.7))
                    Button { model.nudge(-1) } label: { Image(systemName: "minus") }
                        .help("←キーでも動かせます")
                    Text(model.currentParamLabel)
                        .font(.body.monospacedDigit())
                        .frame(minWidth: 50)
                    Button { model.nudge(1) } label: { Image(systemName: "plus") }
                        .help("→キーでも動かせます")
                    let fine = model.fineTabs.contains(model.selectedTab)
                    Button(fine ? "粗く選び直す" : "細かく") { model.toggleFine() }
                    Text(fine ? "細かい段階(\(p.label(p.fineStep)) 刻み)" : "粗い段階")
                        .font(.caption).foregroundStyle(.white.opacity(0.5))
                    Button("今の写真で合わせ直す") { model.rematchLook() }
                        .help("同じ見本で、今の補正の状態から色味を作り直します。露出などを大きく変えたあとに")
                    Button("色味を外す") { model.removeLook() }
                    if let p = model.lookPasteProgress {
                        ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                            .frame(width: 80)
                        Text("貼っています \(p.done) / \(p.total)").font(.caption)
                    } else {
                        Button("ほかの写真にも貼る…") { model.isLookPasteSheetShown = true }
                            .help("この色味を、一覧のほかの写真にまとめてかけます")
                    }
                }
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
    @Environment(\.displayScale) private var displayScale
    /// 虫眼鏡を描く位置(画像上の座標)
    @State private var loupeLocation: CGPoint?
    private let loupeDiameter: CGFloat = 240

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
                Image(decorative: model.compareMode == .before ? (model.beforePreview ?? image) : image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .overlay {
                        // 白飛び(赤)・黒つぶれ(青)。補正後の画像から作るので「補正前」表示のときは出さない
                        if model.showClipping, model.compareMode != .before, let overlay = model.clippingOverlay {
                            Image(decorative: overlay, scale: 1).resizable().scaledToFit().allowsHitTesting(false)
                        }
                    }
                    .overlay {
                        // センサーの飽和(デコード結果から作るので、補正を変えても変わらない)
                        if model.showSensorSaturation, model.compareMode != .before, let s = model.sensorSaturation {
                            Image(decorative: s.image, scale: 1).resizable().interpolation(.none).scaledToFit()
                                .opacity(0.85).allowsHitTesting(false)
                        }
                    }
                    .overlay { if model.compareMode == .split { splitOverlay } }
                    .overlay(alignment: .topLeading) {
                        if model.compareMode == .before { badge("補正前").padding(8) }
                    }
                    .overlay { loupeOverlay }
                    .overlay { colorPickOverlay }
                    .overlay { cropOverlay }
                    .overlay { eyedropperOverlay }
                    .overlay { splitHandle }
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
                if let reason = model.decoderUnsupportedReason {
                    // 壊れているわけではないので、注意の色にしない
                    Text("\(model.displayName(for: model.decoderID)) は \(reason)のため \(model.displayName(for: id)) で表示中")
                        .font(.caption).foregroundStyle(.white.opacity(0.6)).padding(16)
                } else {
                    Text("\(model.displayName(for: model.decoderID)) で開けなかったため \(model.displayName(for: id)) で表示中")
                        .font(.caption).foregroundStyle(.orange).padding(16)
                }
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
    }

    /// 左右で比較: 境目より左に補正前を重ねる。境目はドラッグで動かせる
    private var splitOverlay: some View {
        GeometryReader { geo in
            let x = geo.size.width * model.splitPosition
            ZStack(alignment: .topLeading) {
                if let before = model.beforePreview {
                    Image(decorative: before, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .mask(alignment: .leading) { Rectangle().frame(width: x) }
                }
                Rectangle()
                    .fill(.white)
                    .frame(width: 2, height: geo.size.height)
                    .position(x: x, y: geo.size.height / 2)
                    .allowsHitTesting(false)
                Image(systemName: "arrow.left.and.right.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white, .black.opacity(0.5))
                    .position(x: x, y: geo.size.height / 2)
                    .allowsHitTesting(false)
                badge("補正前").padding(8)
                badge("補正後").padding(8)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .coordinateSpace(name: "split")
        }
    }

    /// 虫眼鏡: マウスの周りをフル解像度の等倍で丸く拡大する
    @ViewBuilder
    private var loupeOverlay: some View {
        if model.loupeEnabled {
            GeometryReader { geo in
                ZStack {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                loupeLocation = location
                                model.moveLoupe(to: CGPoint(x: location.x / geo.size.width,
                                                            y: location.y / geo.size.height),
                                                pixelSize: Int(loupeDiameter * displayScale))
                            case .ended:
                                loupeLocation = nil
                                model.moveLoupe(to: nil, pixelSize: 0)
                            }
                        }
                    if let location = loupeLocation {
                        ZStack {
                            Color(white: 0.15)
                            if let image = model.loupeImage {
                                // scale に画面の倍率を渡して、画像の 1 ピクセル = 画面の 1 ピクセルにする
                                Image(decorative: image, scale: displayScale).interpolation(.none)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .frame(width: loupeDiameter, height: loupeDiameter)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .overlay(alignment: .bottom) {
                            Text("100%").font(.caption2.bold()).foregroundStyle(.white)
                                .padding(.horizontal, 6).background(.black.opacity(0.5), in: Capsule())
                                .padding(.bottom, 10)
                        }
                        .position(location)
                        .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    /// 色ごとの調整のタブ: 大画面をクリックすると、その場所の色の系統を選ぶ
    @ViewBuilder
    private var colorPickOverlay: some View {
        if model.selectedTab == .hsl && !model.isEyedropperActive && !model.loupeEnabled {
            GeometryReader { geo in
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        model.pickColorRange(at: CGPoint(x: location.x / geo.size.width,
                                                         y: location.y / geo.size.height))
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active: NSCursor.crosshair.set()
                        case .ended: NSCursor.arrow.set()
                        }
                    }
            }
        }
    }

    /// 左右で比較の境目をつかむ場所。ほかのクリック用の層(色の系統選び・等倍の場所選び・虫眼鏡)より上に置く。
    /// 境目の周りだけがつかめる範囲なので、それ以外のクリックは下の層に届く
    @ViewBuilder
    private var splitHandle: some View {
        if model.compareMode == .split {
            GeometryReader { geo in
                let x = geo.size.width * model.splitPosition
                Color.clear
                    .frame(width: 24, height: geo.size.height)
                    .contentShape(Rectangle())
                    .position(x: x, y: geo.size.height / 2)
                    .gesture(DragGesture(coordinateSpace: .named("splitHandle")).onChanged { v in
                        model.splitPosition = min(max(v.location.x / geo.size.width, 0.02), 0.98)
                    })
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
            }
            .coordinateSpace(name: "splitHandle")
        }
    }

    /// スポイト中: 十字カーソルにして、クリックした点で WB を決める
    @ViewBuilder
    private var eyedropperOverlay: some View {
        if model.isEyedropperActive {
            GeometryReader { geo in
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        model.applyEyedropper(at: CGPoint(x: location.x / geo.size.width,
                                                          y: location.y / geo.size.height))
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active: NSCursor.crosshair.set()
                        case .ended: NSCursor.arrow.set()
                        }
                    }
            }
            .overlay(alignment: .top) {
                badge("スポイト: 白やグレーの部分をクリック(esc で中止)").padding(8).allowsHitTesting(false)
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
