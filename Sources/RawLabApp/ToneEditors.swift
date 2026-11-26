import DecoderKit
import SwiftUI

/// ヒストグラムを背景に描く(輝度を灰色、RGB を薄く)
private func drawHistogram(_ h: Histogram?, in ctx: GraphicsContext, size: CGSize) {
    guard let h else { return }
    func area(_ values: [Float]) -> Path {
        Path { p in
            p.move(to: CGPoint(x: 0, y: size.height))
            for (i, v) in values.enumerated() {
                p.addLine(to: CGPoint(x: size.width * CGFloat(i) / 255, y: size.height * (1 - CGFloat(v))))
            }
            p.addLine(to: CGPoint(x: size.width, y: size.height))
            p.closeSubpath()
        }
    }
    ctx.fill(area(h.luminance), with: .color(.white.opacity(0.22)))
}

// MARK: - レベル補正

/// レベル補正の 3 つの三角(黒・中間・白)。トーンカーブのグラフの横軸(入力の明るさ)の真下に置く
struct LevelsTrack: View {
    @Bindable var model: AppModel
    let width: CGFloat

    var body: some View {
        let w = width
        let s = model.settings
        let grayX = s.levelsBlack + (s.levelsWhite - s.levelsBlack) * pow(0.5, s.levelsGamma)
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing)
                .frame(width: w, height: 5)
            handle(x: s.levelsBlack * w, fill: .black) { x in
                model.settings.levelsBlack = min(max(x / w, 0), model.settings.levelsWhite - 0.02)
            }
            handle(x: grayX * w, fill: Color(white: 0.5)) { x in
                let b = model.settings.levelsBlack, wh = model.settings.levelsWhite
                let t = min(max((x / w - b) / max(wh - b, 0.001), 0.02), 0.98)
                model.settings.levelsGamma = log(t) / log(0.5)
            }
            handle(x: s.levelsWhite * w, fill: .white) { x in
                model.settings.levelsWhite = max(min(x / w, 1), model.settings.levelsBlack + 0.02)
            }
        }
        .frame(width: w, height: 22)
        .coordinateSpace(name: "levels")
    }

    private func handle(x: CGFloat, fill: Color, onDrag: @escaping (CGFloat) -> Void) -> some View {
        Triangle()
            .fill(fill)
            .overlay(Triangle().stroke(Color.white.opacity(0.8), lineWidth: 1))
            .frame(width: 14, height: 12)
            // つかめる範囲は三角の周りだけ(.position の前に付けないと帯全体がつかむ範囲になる)
            .contentShape(Rectangle().inset(by: -6))
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("levels"))
                .onChanged { onDrag($0.location.x) })
            .position(x: x, y: 13)
    }
}

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
        }
    }
}

// MARK: - レベル補正 + トーンカーブ

/// レベル補正とトーンカーブを 1 つのグラフで。
/// 横軸(入力の明るさ)の真下にレベル補正の三角、グラフの中でカーブの点をドラッグ。
/// 何もない所をクリックすると点を追加、点をダブルクリックで削除
struct CurveEditor: View {
    @Bindable var model: AppModel
    static let presetsWidth: CGFloat = 220
    /// グラフの下のレベル補正の帯の高さ
    static let trackHeight: CGFloat = 24
    @State private var dragIndex: Int?

    private var points: [CurvePoint] { ToneCurve.normalized(model.settings.curve) }

    var body: some View {
        GeometryReader { geo in
            // 高さはパネルに合わせ、幅は余った分だけ横に広げる(最大で高さの 2.2 倍)
            let side = CGSize(width: min(max(geo.size.width - Self.presetsWidth - 16, 120),
                                         (geo.size.height - Self.trackHeight) * 2.2),
                              height: geo.size.height - Self.trackHeight)
            HStack(alignment: .top, spacing: 16) {
              VStack(spacing: 2) {
                Canvas { ctx, size in
                    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.1)))
                    drawHistogram(model.toneHistogram, in: ctx, size: size)
                    // レベル補正で真っ黒・真っ白になる範囲を暗く
                    let lv = model.settings
                    ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width * lv.levelsBlack, height: size.height)),
                             with: .color(.black.opacity(0.45)))
                    ctx.fill(Path(CGRect(x: size.width * lv.levelsWhite, y: 0,
                                         width: size.width * (1 - lv.levelsWhite), height: size.height)),
                             with: .color(.black.opacity(0.45)))
                    for i in 1..<4 {
                        let v = CGFloat(i) / 4
                        var grid = Path()
                        grid.move(to: CGPoint(x: size.width * v, y: 0))
                        grid.addLine(to: CGPoint(x: size.width * v, y: size.height))
                        grid.move(to: CGPoint(x: 0, y: size.height * v))
                        grid.addLine(to: CGPoint(x: size.width, y: size.height * v))
                        ctx.stroke(grid, with: .color(.white.opacity(0.08)), lineWidth: 1)
                    }
                    var diagonal = Path()
                    diagonal.move(to: CGPoint(x: 0, y: size.height))
                    diagonal.addLine(to: CGPoint(x: size.width, y: 0))
                    ctx.stroke(diagonal, with: .color(.white.opacity(0.15)), lineWidth: 1)

                    let pts = points
                    var curve = Path()
                    for i in 0...128 {
                        let x = Double(i) / 128
                        let y = min(max(ToneCurve.evaluate(pts, at: x), 0), 1)
                        let pt = CGPoint(x: size.width * x, y: size.height * (1 - y))
                        if i == 0 { curve.move(to: pt) } else { curve.addLine(to: pt) }
                    }
                    ctx.stroke(curve, with: .color(.white), lineWidth: 1.5)
                    for (i, p) in pts.enumerated() {
                        let c = CGPoint(x: size.width * p.x, y: size.height * (1 - p.y))
                        let r: CGFloat = i == dragIndex ? 5 : 4
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                                 with: .color(i == dragIndex ? Color.accentColor : .white))
                    }
                }
                .frame(width: side.width, height: side.height)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .contentShape(Rectangle())
                .gesture(drag(side: side))
                .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { removePoint(near: $0.location, side: side) })
                LevelsTrack(model: model, width: side.width)
              }

                VStack(alignment: .leading, spacing: 6) {
                    Text("よく使う形").font(.caption).foregroundStyle(.white.opacity(0.6))
                    HStack {
                        preset("直線", [])
                        preset("弱い S 字", [CurvePoint(x: 0.25, y: 0.21), CurvePoint(x: 0.75, y: 0.79)])
                        preset("強い S 字", [CurvePoint(x: 0.25, y: 0.16), CurvePoint(x: 0.75, y: 0.84)])
                    }
                    HStack {
                        preset("明るく", [CurvePoint(x: 0.5, y: 0.6)])
                        preset("暗く", [CurvePoint(x: 0.5, y: 0.4)])
                        preset("黒を締める", [CurvePoint(x: 0.08, y: 0.02)])
                    }
                    if let i = dragIndex, i < points.count {
                        Text(String(format: "入力 %d → 出力 %d", Int(points[i].x * 255), Int(points[i].y * 255)))
                            .font(.caption.monospacedDigit())
                    }
                    Text("グラフ: 何もない所をクリックで点を追加、点をダブルクリックで削除")
                        .font(.caption).foregroundStyle(.white.opacity(0.5))
                    Text("下の三角: レベル補正(左から 黒・中間・白)")
                        .font(.caption).foregroundStyle(.white.opacity(0.5))
                }
                .frame(width: Self.presetsWidth, alignment: .leading)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func preset(_ title: String, _ pts: [CurvePoint]) -> some View {
        Button(title) { model.setCurve(pts) }
    }

    private func drag(side: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                var pts = points
                let x = min(max(v.location.x / side.width, 0), 1)
                let y = min(max(1 - v.location.y / side.height, 0), 1)
                if dragIndex == nil {
                    // 近くの点をつかむ。なければ新しい点を足す
                    let start = v.startLocation
                    if let near = pts.indices.min(by: {
                        distance(pts[$0], start, side) < distance(pts[$1], start, side)
                    }), distance(pts[near], start, side) < 10 {
                        dragIndex = near
                    } else {
                        pts.append(CurvePoint(x: x, y: y))
                        pts.sort { $0.x < $1.x }
                        dragIndex = pts.firstIndex { $0.x == x && $0.y == y }
                    }
                }
                guard let i = dragIndex else { return }
                // 両端は縦だけ、途中の点は隣の点を越えない
                if i == 0 || i == pts.count - 1 {
                    pts[i].y = y
                } else {
                    pts[i].x = min(max(x, pts[i - 1].x + 0.01), pts[i + 1].x - 0.01)
                    pts[i].y = y
                }
                model.setCurve(pts)
            }
            .onEnded { _ in dragIndex = nil }
    }

    private func removePoint(near location: CGPoint, side: CGSize) {
        var pts = points
        guard let i = pts.indices.dropFirst().dropLast().min(by: {
            distance(pts[$0], location, side) < distance(pts[$1], location, side)
        }), distance(pts[i], location, side) < 12 else { return }
        pts.remove(at: i)
        model.setCurve(pts)
    }

    private func distance(_ p: CurvePoint, _ loc: CGPoint, _ side: CGSize) -> CGFloat {
        hypot(p.x * side.width - loc.x, (1 - p.y) * side.height - loc.y)
    }
}
