// RawLab のアプリアイコン(レンズの絞り)を描いて 1024px の PNG にする。
// 使い方: swift scripts/make-icon.swift <出力.png>
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size: CGFloat = 1024
let center = CGPoint(x: size / 2, y: size / 2)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r / 255, g / 255, b / 255, a])!
}
func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}
func point(_ r: CGFloat, _ angle: CGFloat) -> CGPoint {
    CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
}
func circle(_ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2), transform: nil)
}
func ring(_ outer: CGFloat, _ inner: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.addPath(circle(outer))
    p.addPath(circle(inner))
    return p
}
/// 半径 r の円周上で、直線 p + t*d (t>0) と交わる点
func hitCircle(_ p: CGPoint, _ d: CGVector, _ r: CGFloat) -> CGPoint {
    let fx = p.x - center.x, fy = p.y - center.y
    let a = d.dx * d.dx + d.dy * d.dy
    let b = 2 * (fx * d.dx + fy * d.dy)
    let c = fx * fx + fy * fy - r * r
    let t = (-b + sqrt(b * b - 4 * a * c)) / (2 * a)
    return CGPoint(x: p.x + t * d.dx, y: p.y + t * d.dy)
}

// MARK: 台座(角の丸い正方形)と影

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: color(0, 0, 0, 0.45))
ctx.addPath(bodyPath)
ctx.setFillColor(color(30, 31, 34))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
ctx.drawLinearGradient(gradient([(0, color(66, 68, 75)), (1, color(10, 10, 12))]),
                       start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
ctx.restoreGState()

// MARK: 鏡筒(金属のリングとローレット)

let barrelR: CGFloat = 372
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0, 0, 0, 0.6))
ctx.addPath(circle(barrelR))
ctx.setFillColor(color(20, 20, 22))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(ring(barrelR, 330))
ctx.clip(using: .evenOdd)
ctx.drawLinearGradient(gradient([(0, color(232, 234, 238)), (0.45, color(116, 119, 127)),
                                 (0.55, color(72, 75, 82)), (1, color(20, 21, 24))]),
                       start: CGPoint(x: center.x - 260, y: center.y + 300),
                       end: CGPoint(x: center.x + 260, y: center.y - 300), options: [])
// ローレット(細かい刻み)
ctx.setLineWidth(3)
for i in 0..<180 {
    let a = CGFloat(i) / 180 * 2 * .pi
    ctx.move(to: point(340, a))
    ctx.addLine(to: point(364, a))
}
ctx.setStrokeColor(color(0, 0, 0, 0.5))
ctx.strokePath()
ctx.restoreGState()
// 外周のハイライト
ctx.addPath(circle(barrelR - 1.5))
ctx.setStrokeColor(color(255, 255, 255, 0.5))
ctx.setLineWidth(3)
ctx.strokePath()

// 内側の黒いリングと細い面取り
ctx.addPath(circle(330))
ctx.setFillColor(color(10, 10, 12))
ctx.fillPath()
ctx.saveGState()
ctx.addPath(ring(318, 306))
ctx.clip(using: .evenOdd)
ctx.drawLinearGradient(gradient([(0, color(190, 193, 200)), (1, color(18, 19, 22))]),
                       start: CGPoint(x: center.x, y: center.y + 318),
                       end: CGPoint(x: center.x, y: center.y - 318), options: [])
ctx.restoreGState()

// MARK: 絞り羽根(9 枚、少し曲がった羽根を重ねる)

let rim: CGFloat = 306
let blades = 9
let openingR: CGFloat = 128
let rotation: CGFloat = .pi / 2 + 0.25
let vertices = (0..<blades).map { point(openingR, rotation + CGFloat($0) / CGFloat(blades) * 2 * .pi) }

// 開口の各辺を外側へ伸ばした線が羽根の境目(風車状)
var rimPoints: [CGPoint] = []
var controls: [CGPoint] = []
for j in 0..<blades {
    let a = vertices[j], b = vertices[(j + 1) % blades]
    let d = CGVector(dx: b.x - a.x, dy: b.y - a.y)
    let r = hitCircle(b, d, rim + 4)
    rimPoints.append(r)
    // 境目を少し曲げる(羽根の反り)
    let mid = CGPoint(x: (b.x + r.x) / 2, y: (b.y + r.y) / 2)
    let len = hypot(r.x - b.x, r.y - b.y)
    let n = CGVector(dx: -(r.y - b.y) / len, dy: (r.x - b.x) / len)
    controls.append(CGPoint(x: mid.x + n.dx * len * 0.12, y: mid.y + n.dy * len * 0.12))
}

ctx.saveGState()
ctx.addPath(circle(rim))
ctx.clip()
for k in 0..<blades {
    let prev = (k - 1 + blades) % blades
    let vk = vertices[k], vk1 = vertices[(k + 1) % blades]
    let path = CGMutablePath()
    path.move(to: vk)
    path.addQuadCurve(to: rimPoints[prev], control: controls[prev])
    let a0 = atan2(rimPoints[prev].y - center.y, rimPoints[prev].x - center.x)
    var a1 = atan2(rimPoints[k].y - center.y, rimPoints[k].x - center.x)
    if a1 < a0 { a1 += 2 * .pi }
    path.addArc(center: center, radius: rim + 4, startAngle: a0, endAngle: a1, clockwise: false)
    path.addQuadCurve(to: vk1, control: controls[k])
    path.closeSubpath()

    // 金属の羽根: 開口側を暗く、外側と光の当たる側を明るく
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let mid = CGFloat(k) / CGFloat(blades)
    let lift = 0.75 + 0.4 * (0.5 + 0.5 * sin(mid * 2 * .pi + 0.9))  // 羽根ごとに少し明るさを変える
    let dark = color(12 * lift, 13 * lift, 16 * lift)
    let light = color(128 * lift, 133 * lift, 145 * lift)
    let outer = point(rim, atan2(vk.y - center.y, vk.x - center.x) + 0.55)
    ctx.drawLinearGradient(gradient([(0, dark), (0.65, light), (1, color(78 * lift, 82 * lift, 90 * lift))]),
                           start: vk, end: outer, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // 隣の羽根の下に潜る側の影
    ctx.addPath({ let p = CGMutablePath(); p.move(to: vk1); p.addQuadCurve(to: rimPoints[k], control: controls[k]); return p }())
    ctx.setStrokeColor(color(0, 0, 0, 0.7))
    ctx.setLineWidth(16)
    ctx.strokePath()
    ctx.restoreGState()

    // 重なっている側の縁のハイライト
    let edge = CGMutablePath()
    edge.move(to: vk)
    edge.addQuadCurve(to: rimPoints[prev], control: controls[prev])
    ctx.addPath(edge)
    ctx.setStrokeColor(color(235, 238, 245, 0.7))
    ctx.setLineWidth(2.5)
    ctx.strokePath()
}
ctx.restoreGState()

// MARK: 開口(奥のガラスとコーティングの反射)

let opening = CGMutablePath()
opening.addLines(between: vertices)
opening.closeSubpath()
ctx.saveGState()
ctx.addPath(opening)
ctx.clip()
ctx.drawRadialGradient(gradient([(0, color(24, 34, 62)), (0.6, color(3, 4, 9)), (1, color(0, 0, 0))]),
                       startCenter: CGPoint(x: center.x - 20, y: center.y + 25), startRadius: 0,
                       endCenter: center, endRadius: openingR, options: [.drawsAfterEndLocation])
// コーティングの反射(緑・紫・赤みのある弧)
/// 太く薄い線から細く濃い線へ重ねて、にじんだ光にする
func arc(_ r: CGFloat, _ from: CGFloat, _ to: CGFloat, _ c: CGColor, _ w: CGFloat, dx: CGFloat = 0, dy: CGFloat = 0) {
    let alpha = c.alpha
    for (scale, a) in [(5.0, 0.10), (3.2, 0.16), (2.0, 0.28), (1.0, 0.55)] as [(CGFloat, CGFloat)] {
        ctx.addArc(center: CGPoint(x: center.x + dx, y: center.y + dy), radius: r, startAngle: from, endAngle: to, clockwise: false)
        ctx.setStrokeColor(c.copy(alpha: alpha * a)!)
        ctx.setLineWidth(w * scale)
        ctx.setLineCap(.round)
        ctx.strokePath()
    }
}
arc(96, 2.2, 3.1, color(70, 200, 120, 0.55), 9, dx: 6, dy: -4)
arc(70, 1.9, 2.9, color(150, 90, 230, 0.6), 7, dx: 10, dy: -8)
arc(108, 5.3, 6.0, color(230, 80, 90, 0.35), 6)
arc(44, 5.0, 5.9, color(80, 150, 255, 0.45), 5, dx: -4, dy: 6)
// 強い光の点
ctx.drawRadialGradient(gradient([(0, color(255, 255, 255, 0.95)), (1, color(255, 255, 255, 0))]),
                       startCenter: CGPoint(x: center.x - 42, y: center.y + 46), startRadius: 0,
                       endCenter: CGPoint(x: center.x - 42, y: center.y + 46), endRadius: 22, options: [])
ctx.restoreGState()
// 開口の縁
ctx.addPath(opening)
ctx.setStrokeColor(color(0, 0, 0, 0.8))
ctx.setLineWidth(3)
ctx.strokePath()

// MARK: レンズ全体にかかるガラスの映り込み

ctx.saveGState()
ctx.addPath(circle(330))
ctx.clip()
ctx.drawRadialGradient(gradient([(0, color(255, 255, 255, 0.24)), (1, color(255, 255, 255, 0))]),
                       startCenter: CGPoint(x: center.x - 120, y: center.y + 170), startRadius: 0,
                       endCenter: CGPoint(x: center.x - 120, y: center.y + 170), endRadius: 260, options: [])
ctx.restoreGState()

// MARK: 書き出し

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.png")
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("✓ \(out.path)")
