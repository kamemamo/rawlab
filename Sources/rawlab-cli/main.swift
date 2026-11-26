import CoreImage
import DecoderKit
import Foundation

let usage = """
使い方:
  rawlab decoders
  rawlab info <file.NEF>...
  rawlab develop <file.NEF>... [options]
  rawlab compare <file.NEF> [options] [--crop N]

options:
  --decoder <id>        coreimage | libraw(既定: libraw)
  --out <dir>           書き出し先(既定: ./out)
  --format <f>          jpeg | tiff | heic(既定: jpeg)
  --ev <n>              露出補正 (EV)
  --contrast <n>        -1...1
  --shadows <n>         -1...1
  --highlights <n>      0...1
  --sat <n>             彩度 -1...1
  --nr <n>              デコーダー側ノイズリダクション 0...1
  --demosaic <m>        auto|linear|vng|ppg|ahd|dcb|dht|aahd(LibRaw のみ)
  --half                半分サイズで高速デコード
  --crop <N>            compare: 中央 N×N px を等倍で切り出して比較
"""

struct Options {
    var files: [URL] = []
    var decoder = "libraw"
    var out = URL(fileURLWithPath: "out")
    var format = ExportFormat.jpeg
    var decode = DecodeOptions()
    var develop = DevelopSettings()
    var crop: Int?
}

func parse(_ args: ArraySlice<String>) throws -> Options {
    var o = Options()
    var it = args.makeIterator()
    func value(_ name: String) throws -> String {
        guard let v = it.next() else { throw DecoderError.failed("\(name) に値がありません") }
        return v
    }
    func number(_ name: String) throws -> Double {
        let v = try value(name)
        guard let d = Double(v) else { throw DecoderError.failed("\(name) は数値: \(v)") }
        return d
    }
    while let a = it.next() {
        switch a {
        case "--decoder": o.decoder = try value(a)
        case "--out": o.out = URL(fileURLWithPath: try value(a))
        case "--format":
            let v = try value(a)
            guard let f = ExportFormat(rawValue: v) else { throw DecoderError.failed("不明な形式: \(v)") }
            o.format = f
        case "--ev": o.develop.exposure = try number(a)
        case "--contrast": o.develop.contrast = try number(a)
        case "--shadows": o.develop.shadows = try number(a)
        case "--highlights": o.develop.highlights = try number(a)
        case "--sat": o.develop.saturation = try number(a)
        case "--nr": o.decode.noiseReduction = try number(a)
        case "--demosaic":
            let v = try value(a)
            guard let m = DemosaicMethod(rawValue: v) else { throw DecoderError.failed("不明なデモザイク: \(v)") }
            o.decode.demosaic = m
        case "--half": o.decode.halfSize = true
        case "--crop": o.crop = Int(try number(a))
        default:
            if a.hasPrefix("--") { throw DecoderError.failed("不明なオプション: \(a)") }
            o.files.append(URL(fileURLWithPath: a))
        }
    }
    return o
}

func fmt(_ t: TimeInterval) -> String { String(format: "%.2fs", t) }

func printInfo(_ url: URL) throws {
    let m = try DecoderRegistry.metadata(url)
    print("■ \(url.lastPathComponent)")
    print("  カメラ     : \(m.make) \(m.model)")
    print("  レンズ     : \(m.lens.isEmpty ? "-" : m.lens)")
    print("  露出       : ISO \(Int(m.iso))  \(m.shutterString)  f/\(String(format: "%.1f", m.aperture))  \(Int(m.focalLength))mm")
    print("  サイズ     : \(m.width) × \(m.height)")
    if let d = m.captureDate { print("  撮影日時   : \(d.formatted(date: .numeric, time: .standard))") }
    if let pc = m.pictureControl { print("  ピクチャーコントロール : \(pc)") }
    if let adl = m.activeDLighting { print("  アクティブD-ライティング : \(adl)") }
    let ok = DecoderRegistry.all.filter { $0.canDecode(url) }.map(\.id)
    print("  対応デコーダー : \(ok.joined(separator: ", "))")
}

func develop(_ o: Options) throws {
    try FileManager.default.createDirectory(at: o.out, withIntermediateDirectories: true)
    for url in o.files {
        let decoded = try DecoderRegistry.decode(url, preferred: o.decoder, options: o.decode)
        let result = DevelopPipeline.apply(o.develop, to: decoded.image)
        let dest = o.out.appendingPathComponent(
            url.deletingPathExtension().lastPathComponent + "_\(decoded.decoderID).\(o.format.fileExtension)")
        let t0 = Date()
        try Exporter.export(result, to: dest, format: o.format)
        let note = decoded.decoderID == o.decoder ? "" : "(\(o.decoder) が失敗したため代替)"
        print("✓ \(dest.path)  [\(decoded.decoderID)\(note)] デコード \(fmt(decoded.decodeTime)) / 書き出し \(fmt(Date().timeIntervalSince(t0)))")
    }
}

/// 全デコーダーで同じ設定を当て、個別ファイル + 横並び画像を書き出す
func compare(_ o: Options) throws {
    guard let url = o.files.first else { throw DecoderError.failed("ファイルを指定してください") }
    try FileManager.default.createDirectory(at: o.out, withIntermediateDirectories: true)
    let base = url.deletingPathExtension().lastPathComponent
    var panels: [CIImage] = []

    for decoder in DecoderRegistry.all where decoder.canDecode(url) {
        do {
            let decoded = try decoder.decode(url, options: o.decode)
            var img = DevelopPipeline.apply(o.develop, to: decoded.image)
            if let n = o.crop {
                let e = img.extent
                let side = CGFloat(min(n, Int(min(e.width, e.height))))
                let rect = CGRect(x: e.midX - side / 2, y: e.midY - side / 2, width: side, height: side).integral
                img = img.cropped(to: rect)
            }
            img = img.transformed(by: .init(translationX: -img.extent.minX, y: -img.extent.minY))
            let dest = o.out.appendingPathComponent("\(base)_\(decoder.id).\(o.format.fileExtension)")
            try Exporter.export(img, to: dest, format: o.format)
            print("✓ \(decoder.displayName.padding(toLength: 16, withPad: " ", startingAt: 0)) デコード \(fmt(decoded.decodeTime))  \(Int(img.extent.width))×\(Int(img.extent.height))  → \(dest.lastPathComponent)")
            panels.append(img)
        } catch {
            print("✗ \(decoder.displayName): \(error.localizedDescription)")
        }
    }

    guard panels.count > 1 else { return }
    let height = panels.map(\.extent.height).min()!
    let gap: CGFloat = 16
    var x: CGFloat = 0
    var sheet = CIImage.empty()
    for p in panels {
        let s = height / p.extent.height
        let placed = p.transformed(by: CGAffineTransform(scaleX: s, y: s).translatedBy(x: x / s, y: 0))
        sheet = placed.composited(over: sheet)
        x += p.extent.width * s + gap
    }
    let bg = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.1))
        .cropped(to: CGRect(x: 0, y: 0, width: x - gap, height: height))
    let dest = o.out.appendingPathComponent("\(base)_compare.jpg")
    try Exporter.export(sheet.composited(over: bg), to: dest, format: .jpeg)
    print("✓ 横並び比較 → \(dest.path)(左から \(DecoderRegistry.ids.joined(separator: " / ")))")
}

let args = CommandLine.arguments.dropFirst()
do {
    guard let command = args.first else { print(usage); exit(1) }
    let o = try parse(args.dropFirst())
    switch command {
    case "decoders":
        for d in DecoderRegistry.all { print("\(d.id.padding(toLength: 10, withPad: " ", startingAt: 0)) \(d.displayName)") }
    case "info":
        for f in o.files { try printInfo(f) }
    case "develop":
        try develop(o)
    case "compare":
        try compare(o)
    default:
        print(usage); exit(1)
    }
} catch {
    FileHandle.standardError.write(Data("エラー: \(error.localizedDescription)\n".utf8))
    exit(1)
}
