import CoreGraphics
import Foundation

/// 大画面で見る色(全色、または R / G / B のどれか 1 色を白黒で)
enum ChannelView: String, CaseIterable, Identifiable, Sendable {
    case rgb, red, green, blue
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rgb: "RGB"
        case .red: "R"
        case .green: "G"
        case .blue: "B"
        }
    }
    /// RGBA の何番目か(全色なら nil)
    var index: Int? {
        switch self {
        case .rgb: nil
        case .red: 0
        case .green: 1
        case .blue: 2
        }
    }
}

/// 表示中の画像のヒストグラム(R / G / B / 輝度、各 256 段階)
struct Histogram: Sendable {
    var red: [Float]
    var green: [Float]
    var blue: [Float]
    var luminance: [Float]
    /// 輝度の画素数そのもの(表示用に縮めていない。「自動」レベルの計算用)
    var luminanceCounts: [Float]
    /// どれかのチャンネルが 255 に達している画素の割合
    var highlightClipping: Double
    /// すべてのチャンネルが 0 の画素の割合
    var shadowClipping: Double
    /// 色ごとの白飛び・黒つぶれの割合 [R, G, B]
    var channelHighlightClipping: [Double] = [0, 0, 0]
    var channelShadowClipping: [Double] = [0, 0, 0]

    func highlightClipping(_ c: ChannelView) -> Double { c.index.map { channelHighlightClipping[$0] } ?? highlightClipping }
    func shadowClipping(_ c: ChannelView) -> Double { c.index.map { channelShadowClipping[$0] } ?? shadowClipping }

    /// 縮小して数える(長辺 512 で十分)
    static func compute(from image: CGImage, maxPixel: Int = 512) -> Histogram? {
        let scale = min(1, Double(maxPixel) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale))
        let h = max(1, Int(Double(image.height) * scale))
        guard let pixels = rgba8(image, width: w, height: h) else { return nil }

        var r = [Float](repeating: 0, count: 256)
        var g = r, b = r, l = r
        var high = 0, low = 0
        let count = w * h
        pixels.withUnsafeBufferPointer { p in
            for i in 0..<count {
                let R = Int(p[i * 4]), G = Int(p[i * 4 + 1]), B = Int(p[i * 4 + 2])
                r[R] += 1
                g[G] += 1
                b[B] += 1
                // Rec.709 の重みで輝度
                l[min(255, (R * 54 + G * 183 + B * 19) >> 8)] += 1
                if R == 255 || G == 255 || B == 255 { high += 1 }
                if R == 0 && G == 0 && B == 0 { low += 1 }
            }
        }
        // 端の山(白飛び・黒つぶれ)で全体が潰れないよう、端を除いた最大値で正規化
        let n = Float(count)
        let chHigh = [r[255], g[255], b[255]].map { Double($0 / n) }
        let chLow = [r[0], g[0], b[0]].map { Double($0 / n) }
        let peak = max(1, [r, g, b, l].map { $0[1..<255].max() ?? 1 }.max() ?? 1)
        func norm(_ a: [Float]) -> [Float] { a.map { min($0 / peak, 1) } }
        return Histogram(red: norm(r), green: norm(g), blue: norm(b), luminance: norm(l), luminanceCounts: l,
                         highlightClipping: Double(high) / Double(count),
                         shadowClipping: Double(low) / Double(count),
                         channelHighlightClipping: chHigh, channelShadowClipping: chLow)
    }

    /// 白飛び(赤)・黒つぶれ(青)だけを塗った重ね表示用の画像。
    /// channel を指定すると、その色だけで判定する(255 なら白飛び、0 なら黒つぶれ)
    static func clippingOverlay(from image: CGImage, channel: Int? = nil) -> CGImage? {
        let w = image.width, h = image.height
        guard var pixels = rgba8(image, width: w, height: h) else { return nil }
        pixels.withUnsafeMutableBufferPointer { p in
            for i in 0..<(w * h) {
                let R = p[i * 4], G = p[i * 4 + 1], B = p[i * 4 + 2]
                let high: Bool, low: Bool
                if let k = channel {
                    high = p[i * 4 + k] == 255
                    low = p[i * 4 + k] == 0
                } else {
                    high = R == 255 || G == 255 || B == 255
                    low = R == 0 && G == 0 && B == 0
                }
                if high {
                    (p[i * 4], p[i * 4 + 1], p[i * 4 + 2], p[i * 4 + 3]) = (255, 40, 40, 255)
                } else if low {
                    (p[i * 4], p[i * 4 + 1], p[i * 4 + 2], p[i * 4 + 3]) = (40, 110, 255, 255)
                } else {
                    (p[i * 4], p[i * 4 + 1], p[i * 4 + 2], p[i * 4 + 3]) = (0, 0, 0, 0)
                }
            }
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// 画像を指定サイズの RGBA8(表示と同じ色空間のまま)に描き直して画素を取り出す
    private static func rgba8(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? pixels : nil
    }
}

import SwiftUI

/// ヒストグラムの表示。左右の三角は黒つぶれ・白飛びの警告で、押すと大画面に色で表示する
struct HistogramView: View {
    let histogram: Histogram?
    @Binding var showClipping: Bool
    var channel: ChannelView = .rgb

    var body: some View {
        VStack(spacing: 4) {
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.12)))
                // 4 分割の目盛り
                for i in 1..<4 {
                    let x = size.width * CGFloat(i) / 4
                    ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                               with: .color(.white.opacity(0.08)), lineWidth: 1)
                }
                guard let h = histogram else { return }
                ctx.blendMode = .screen
                for (i, values, color) in [(0, h.red, Color.red), (1, h.green, Color.green), (2, h.blue, Color.blue)] {
                    // 1 色だけ見ているときは、その色をはっきり、他は薄く
                    let opacity = channel.index == nil ? 0.75 : (channel.index == i ? 0.95 : 0.12)
                    ctx.fill(area(values, size), with: .color(color.opacity(opacity)))
                }
                ctx.blendMode = .normal
                if channel == .rgb {
                    ctx.stroke(line(h.luminance, size), with: .color(.white.opacity(0.7)), lineWidth: 1)
                }
            }
            .frame(height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .topLeading) { warning(h: histogram?.shadowClipping(channel), color: .blue) }
            .overlay(alignment: .topTrailing) { warning(h: histogram?.highlightClipping(channel), color: .red) }

            HStack {
                Text("黒つぶれ \(percent(histogram?.shadowClipping(channel)))")
                Spacer()
                Toggle("大画面に表示", isOn: $showClipping)
                    .toggleStyle(.checkbox)
                    .help("白飛びを赤、黒つぶれを青で表示")
                Spacer()
                Text("白飛び \(percent(histogram?.highlightClipping(channel)))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func area(_ values: [Float], _ size: CGSize) -> Path {
        Path { p in
            p.move(to: CGPoint(x: 0, y: size.height))
            for (i, v) in values.enumerated() {
                p.addLine(to: CGPoint(x: size.width * CGFloat(i) / 255, y: size.height * (1 - CGFloat(v))))
            }
            p.addLine(to: CGPoint(x: size.width, y: size.height))
            p.closeSubpath()
        }
    }

    private func line(_ values: [Float], _ size: CGSize) -> Path {
        Path { p in
            for (i, v) in values.enumerated() {
                let pt = CGPoint(x: size.width * CGFloat(i) / 255, y: size.height * (1 - CGFloat(v)))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        }
    }

    /// 0.1% を超えたら三角を点灯。押すと大画面の表示を切り替え
    private func warning(h: Double?, color: Color) -> some View {
        let on = (h ?? 0) > 0.001
        return Button { showClipping.toggle() } label: {
            Image(systemName: "triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(on ? color : Color.white.opacity(0.25))
                .padding(4)
        }
        .buttonStyle(.plain)
        .help("押すと白飛び・黒つぶれを大画面に表示")
    }

    private func percent(_ v: Double?) -> String {
        guard let v else { return "-" }
        return String(format: "%.1f%%", v * 100)
    }
}
