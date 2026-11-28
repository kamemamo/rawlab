import AppKit
import DecoderKit
import SwiftUI

/// トリミングの比率の固定
enum CropAspect: String, CaseIterable, Identifiable {
    case free, original, square, r4x3, r3x2, r16x9, r5x4

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: "自由"
        case .original: "元の比率"
        case .square: "1:1"
        case .r4x3: "4:3"
        case .r3x2: "3:2"
        case .r16x9: "16:9"
        case .r5x4: "5:4"
        }
    }

    /// 縦横を入れ替えられるか(自由と 1:1 は入れ替えても同じ)
    var canRotate: Bool { self != .free && self != .square }

    /// 範囲の「割合での横 ÷ 縦」。画素での比率 ÷ 画像の横縦比。自由なら nil
    func normalizedRatio(imageAspect a: Double, portrait: Bool) -> Double? {
        let landscape: Double
        switch self {
        case .free: return nil
        case .original: landscape = a >= 1 ? a : 1 / a
        case .square: landscape = 1
        case .r4x3: landscape = 4.0 / 3
        case .r3x2: landscape = 3.0 / 2
        case .r16x9: landscape = 16.0 / 9
        case .r5x4: landscape = 5.0 / 4
        }
        let pixel = portrait ? 1 / landscape : landscape
        return pixel / max(a, 1e-6)
    }
}

/// トリミングの範囲の計算(すべて画像に対する割合、左上原点)
enum CropGeometry {
    enum Handle: CaseIterable {
        case move, left, right, top, bottom, topLeft, topRight, bottomLeft, bottomRight

        var movesLeft: Bool { [.left, .topLeft, .bottomLeft].contains(self) }
        var movesRight: Bool { [.right, .topRight, .bottomRight].contains(self) }
        var movesTop: Bool { [.top, .topLeft, .topRight].contains(self) }
        var movesBottom: Bool { [.bottom, .bottomLeft, .bottomRight].contains(self) }
        var isCorner: Bool { [.topLeft, .topRight, .bottomLeft, .bottomRight].contains(self) }
    }

    /// いちばん小さい範囲(画像の 2%)
    static let minSize = 0.02

    /// r の中に入る、比率 k(割合での横 ÷ 縦)で最大の範囲。中心はそのまま
    static func fit(_ r: CropRect, ratio k: Double) -> CropRect {
        var w = r.width, h = r.height
        if w / h > k { w = h * k } else { h = w / k }
        return CropRect(x: r.x + (r.width - w) / 2, y: r.y + (r.height - h) / 2, width: w, height: h)
    }

    /// つまみを (dx, dy) だけ動かしたときの範囲。k があればその比率を保つ
    static func drag(_ r: CropRect, _ handle: Handle, dx: Double, dy: Double, ratio k: Double?) -> CropRect {
        let m = minSize
        var x0 = r.x, y0 = r.y, x1 = r.x + r.width, y1 = r.y + r.height
        if handle == .move {
            let mx = min(max(dx, -x0), 1 - x1), my = min(max(dy, -y0), 1 - y1)
            return CropRect(x: x0 + mx, y: y0 + my, width: r.width, height: r.height)
        }
        guard let k else {
            if handle.movesLeft { x0 = min(max(x0 + dx, 0), x1 - m) }
            if handle.movesRight { x1 = min(max(x1 + dx, x0 + m), 1) }
            if handle.movesTop { y0 = min(max(y0 + dy, 0), y1 - m) }
            if handle.movesBottom { y1 = min(max(y1 + dy, y0 + m), 1) }
            return CropRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
        if handle.isCorner {
            // 反対の角を止めて、大きく動いた方に合わせる
            let sx: Double = handle.movesRight ? 1 : -1, sy: Double = handle.movesBottom ? 1 : -1
            let ax = sx > 0 ? x0 : x1, ay = sy > 0 ? y0 : y1
            let px = (sx > 0 ? x1 : x0) + dx, py = (sy > 0 ? y1 : y0) + dy
            var w = max(sx * (px - ax), m), h = max(sy * (py - ay), m)
            w = max(w, h * k)
            h = w / k
            let maxW = sx > 0 ? 1 - ax : ax, maxH = sy > 0 ? 1 - ay : ay
            if w > maxW { w = maxW; h = w / k }
            if h > maxH { h = maxH; w = h * k }
            return CropRect(x: sx > 0 ? ax : ax - w, y: sy > 0 ? ay : ay - h, width: w, height: h)
        }
        if handle == .left || handle == .right {
            // 横の辺: 反対の辺を止めて幅を決め、高さは中心をそろえて比率から
            let sx: Double = handle == .right ? 1 : -1
            let ax = sx > 0 ? x0 : x1
            var w = max(sx * ((sx > 0 ? x1 : x0) + dx - ax), m)
            w = min(w, sx > 0 ? 1 - ax : ax)
            var h = w / k
            if h > 1 { h = 1; w = h * k }
            let cy = (y0 + y1) / 2
            let y = min(max(cy - h / 2, 0), 1 - h)
            return CropRect(x: sx > 0 ? ax : ax - w, y: y, width: w, height: h)
        }
        // 縦の辺
        let sy: Double = handle == .bottom ? 1 : -1
        let ay = sy > 0 ? y0 : y1
        var h = max(sy * ((sy > 0 ? y1 : y0) + dy - ay), m)
        h = min(h, sy > 0 ? 1 - ay : ay)
        var w = h * k
        if w > 1 { w = 1; h = w / k }
        let cx = (x0 + x1) / 2
        let x = min(max(cx - w / 2, 0), 1 - w)
        return CropRect(x: x, y: sy > 0 ? ay : ay - h, width: w, height: h)
    }
}

/// 大画面に重ねるトリミングの枠。外側を暗くし、三分割の線とつまみを出す。
/// 枠の中をドラッグで移動、角と辺のつまみで大きさを変える
struct CropEditor: View {
    let model: AppModel
    @State private var dragStart: CropRect?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let r = model.cropDraft
            let rect = CGRect(x: r.x * size.width, y: r.y * size.height,
                              width: r.width * size.width, height: r.height * size.height)
            ZStack(alignment: .topLeading) {
                // 外側を暗く
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: size))
                    p.addRect(rect)
                }
                .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                // 三分割の線と枠
                Path { p in
                    for i in 1...2 {
                        let x = rect.minX + rect.width * CGFloat(i) / 3
                        let y = rect.minY + rect.height * CGFloat(i) / 3
                        p.move(to: CGPoint(x: x, y: rect.minY)); p.addLine(to: CGPoint(x: x, y: rect.maxY))
                        p.move(to: CGPoint(x: rect.minX, y: y)); p.addLine(to: CGPoint(x: rect.maxX, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.35), lineWidth: 1)
                .allowsHitTesting(false)
                Rectangle()
                    .stroke(Color.white, lineWidth: 1.5)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
                // 枠の中: ドラッグで移動
                Color.black.opacity(0.001)
                    .frame(width: rect.width, height: rect.height)
                    .contentShape(Rectangle())
                    .offset(x: rect.minX, y: rect.minY)
                    .gesture(drag(.move, size))
                    .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
                ForEach(Array(CropGeometry.Handle.allCases.dropFirst()), id: \.self) { h in
                    handle(h, rect: rect, size: size)
                }
            }
        }
    }

    private func drag(_ h: CropGeometry.Handle, _ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { v in
                let start = dragStart ?? model.cropDraft
                if dragStart == nil { dragStart = start }
                let k = model.cropAspect.normalizedRatio(imageAspect: model.imageAspect, portrait: model.cropPortrait)
                model.cropDraft = CropGeometry.drag(start, h, dx: v.translation.width / size.width,
                                                    dy: v.translation.height / size.height, ratio: k)
            }
            .onEnded { _ in dragStart = nil }
    }

    /// つまみ: 角は L 字、辺は短い棒。つかめる範囲は見た目より広く
    private func handle(_ h: CropGeometry.Handle, rect: CGRect, size: CGSize) -> some View {
        let x = h.movesLeft ? rect.minX : h.movesRight ? rect.maxX : rect.midX
        let y = h.movesTop ? rect.minY : h.movesBottom ? rect.maxY : rect.midY
        let hit: CGFloat = 24
        return ZStack {
            Color.black.opacity(0.001)
            if h.isCorner {
                Path { p in
                    let l: CGFloat = 16
                    let dx: CGFloat = h.movesLeft ? 1 : -1, dy: CGFloat = h.movesTop ? 1 : -1
                    let c = CGPoint(x: hit / 2, y: hit / 2)
                    p.move(to: CGPoint(x: c.x + dx * l, y: c.y)); p.addLine(to: c)
                    p.addLine(to: CGPoint(x: c.x, y: c.y + dy * l))
                }
                .stroke(Color.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .square))
            } else {
                let horizontal = h == .top || h == .bottom
                Capsule().fill(Color.white)
                    .frame(width: horizontal ? 18 : 3.5, height: horizontal ? 3.5 : 18)
            }
        }
        .frame(width: hit, height: hit)
        .contentShape(Rectangle())
        .position(x: x, y: y)
        .gesture(drag(h, size))
        .onHover { inside in
            if inside { cursor(h).push() } else { NSCursor.pop() }
        }
    }

    private func cursor(_ h: CropGeometry.Handle) -> NSCursor {
        switch h {
        case .left, .right: .resizeLeftRight
        case .top, .bottom: .resizeUpDown
        default: .crosshair
        }
    }
}
