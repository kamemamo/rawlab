import CoreImage
import DecoderKit
import Foundation
import ImageIO
import LibraryKit

let usage = """
使い方:
  rawlab decoders
  rawlab info <file.NEF>...
  rawlab develop <file.NEF>... [options]
  rawlab compare <file.NEF> [options] [--crop N]
  rawlab wb <file.NEF> <x> <y>      点 (0〜1, 左上原点) が無彩色になる WB を求める

ライブラリ(~/Pictures/RawLab Library、環境変数 RAWLAB_LIBRARY で変更可):
  rawlab library                    ライブラリの概要
  rawlab library add <folder>...    RAW フォルダを登録してスキャン
  rawlab library scan               全フォルダを再スキャン
  rawlab library photos             写真・バージョン・書き出し状態の一覧
  rawlab library export <file.NEF>... [--format f]  全バージョンを書き出し先へ

options:
  --decoder <id>        coreimage | libraw(既定: libraw)
  --out <dir>           書き出し先(既定: ./out)
  --format <f>          jpeg | tiff | heic(既定: jpeg)
  --ev <n>              露出補正 (EV)
  --contrast <n>        -1...1
  --shadows <n>         -1...1
  --trim <x,y,w,h>      トリミング(画像に対する割合、左上原点。例: 0.1,0.1,0.5,0.5)
  --shadow-range <n>    シャドウが効く範囲(ヒストグラムの左からの割合、既定 0.25。0 で以前の方式)
  --highlights <n>      0...1
  --sat <n>             彩度 -1...1
  --nr <n>              デコーダー側ノイズリダクション 0...1
  --demosaic <m>        auto|linear|vng|ppg|ahd|dcb|dht|aahd(LibRaw のみ)
  --sensor-map          センサーの飽和の地図も PNG で書き出す(RawLab エンジン / RawLab ネイティブ。赤・緑・青 = その色が飽和)
  --half                半分サイズで高速デコード
  --highlight <m>       白飛び: clip(白にする)| reconstruct(色を補って復元。RawLab エンジン / RawLab ネイティブ / LibRaw)
  --highlight-strength <n>  色を補って復元の強さ 0...1(0 = 切り捨てと同じ。既定 1)
  --keep-below-black    黒より暗い値(暗部のノイズの下半分)を切らずに残す(RawLab エンジン / RawLab ネイティブ)
  --measured-black      遮光画素で黒と行ごとの縞を測って引く(RawLab ネイティブ・遮光画素のある DNG)
  --shadow-nr <n>       測ったノイズに合わせた暗部のノイズ低減 0...1(RawLab エンジン / RawLab ネイティブ)
  --rolloff <n>         ハイライト圧縮 0...1(1 を超えた明るさを丸めて収める)
  --ev-r/--ev-g/--ev-b <n>  色ごとの露出 (EV)
  --hsl <系統:色相,彩度,明度>  色ごとの調整(何回でも)。例: --hsl blue:0,0.6,-0.4
  --levels <b,g,w>      レベル補正(黒,中間,白。例: 20,1.2,235)
  --curve <x:y,...>     トーンカーブ(0〜255。例: 64:48,192:208)
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
    /// センサーの飽和の地図も PNG で書き出す
    var sensorMap = false
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
        case "--shadow-range": o.develop.shadowRange = try number(a)
        case "--trim":
            let v = try value(a).split(separator: ",").compactMap { Double($0) }
            guard v.count == 4 else { throw DecoderError.failed("--trim は x,y,w,h の 4 つの数") }
            o.develop.crop = CropRect(x: v[0], y: v[1], width: v[2], height: v[3])
        case "--highlights": o.develop.highlights = try number(a)
        case "--sat": o.develop.saturation = try number(a)
        case "--nr": o.decode.noiseReduction = try number(a)
        case "--demosaic":
            let v = try value(a)
            guard let m = DemosaicMethod(rawValue: v) else { throw DecoderError.failed("不明なデモザイク: \(v)") }
            o.decode.demosaic = m
        case "--half": o.decode.halfSize = true
        case "--sensor-map": o.sensorMap = true
        case "--highlight":
            let v = try value(a)
            guard let m = HighlightMode(rawValue: v) else { throw DecoderError.failed("--highlight は clip か reconstruct") }
            o.decode.highlight = m
        case "--highlight-strength": o.decode.highlightStrength = try number(a)
        case "--keep-below-black": o.decode.keepBelowBlack = true
        case "--measured-black": o.decode.measuredBlack = true
        case "--shadow-nr": o.decode.shadowNoiseReduction = try number(a)
        case "--rolloff": o.develop.highlightRolloff = try number(a)
        case "--hsl":
            // 系統:色相,彩度,明度  例: blue:0,0.6,-0.4
            let v = try value(a)
            let parts = v.split(separator: ":")
            guard parts.count == 2,
                  let range = ColorRange.allCases.first(where: { "\($0)" == parts[0] }) else {
                throw DecoderError.failed("--hsl は red|orange|yellow|green|aqua|blue|purple|magenta:色相,彩度,明度")
            }
            let n = parts[1].split(separator: ",").compactMap { Double($0) }
            guard n.count == 3 else { throw DecoderError.failed("--hsl の値は 色相,彩度,明度 の 3 つ") }
            o.develop.colorAdjustments[range].hue = n[0]
            o.develop.colorAdjustments[range].saturation = n[1]
            o.develop.colorAdjustments[range].luminance = n[2]
        case "--ev-r": o.develop.exposureR = try number(a)
        case "--ev-g": o.develop.exposureG = try number(a)
        case "--ev-b": o.develop.exposureB = try number(a)
        case "--levels":
            // 黒,中間,白(黒と白は 0〜255、中間は 1.0 で変化なし)
            let v = try value(a).split(separator: ",").compactMap { Double($0) }
            guard v.count == 3 else { throw DecoderError.failed("--levels は 黒,中間,白 の 3 つ") }
            o.develop.levelsBlack = v[0] / 255
            o.develop.levelsGamma = v[1]
            o.develop.levelsWhite = v[2] / 255
        case "--curve":
            // 入力:出力 を , 区切り(0〜255)。例: 64:48,192:208
            o.develop.curve = try value(a).split(separator: ",").map { pair in
                let xy = pair.split(separator: ":").compactMap { Double($0) }
                guard xy.count == 2 else { throw DecoderError.failed("--curve は 入力:出力 の並び") }
                return CurvePoint(x: xy[0] / 255, y: xy[1] / 255)
            }
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
    for d in DecoderRegistry.all {
        if let reason = d.unsupportedReason(url) { print("  非対応     : \(d.id)(\(reason))") }
    }
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
        let reason = DecoderRegistry.decoder(id: o.decoder)?.unsupportedReason(url)
        let note = decoded.decoderID == o.decoder ? ""
            : reason.map { "(\(o.decoder) は \($0)のため代替)" } ?? "(\(o.decoder) が失敗したため代替)"
        print("✓ \(dest.path)  [\(decoded.decoderID)\(note)] デコード \(fmt(decoded.decodeTime)) / 書き出し \(fmt(Date().timeIntervalSince(t0)))")
        if let sat = decoded.sensorSaturation {
            let p = { (v: Double) in String(format: "%.2f%%", v * 100) }
            if let d = decoded.darkInfo {
                var line = String(format: "  黒: ファイル %.1f", d.declaredBlack)
                if let m = d.measuredBlack { line += String(format: " / 遮光画素 %.1f(行ごとの縞 %.2f)", m, d.rowBanding ?? 0) }
                if let s = d.noiseAtBlack { line += String(format: "  黒のあたりのノイズ %.3f%%", s * 100) }
                print(line)
            }
            print("  センサーの飽和: R \(p(sat.fraction[0]))  G \(p(sat.fraction[1]))  B \(p(sat.fraction[2]))  どれか \(p(sat.anyFraction))")
            if o.sensorMap, let cg = DevelopPipeline.context.createCGImage(sat.map, from: sat.map.extent),
               let png = CGImageDestinationCreateWithURL(
                   dest.deletingPathExtension().appendingPathExtension("sensor.png") as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(png, cg, nil)
                CGImageDestinationFinalize(png)
            }
        }
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

func library(_ args: ArraySlice<String>) throws {
    let catalog = try Catalog()
    LookStore.directory = catalog.libraryURL.appendingPathComponent("Looks")
    let sub = args.first ?? ""
    let rest = args.dropFirst()
    switch sub {
    case "":
        print("ライブラリ : \(catalog.libraryURL.path)")
        print("書き出し先 : \(catalog.exportRoot.path)")
        for f in try catalog.folders() {
            let count = try catalog.photos(folderID: f.id).count
            print("  \(f.isAvailable ? "●" : "○") \(f.path)  (\(count) 枚)")
        }
    case "add":
        for path in rest {
            let folder = try catalog.addFolder(URL(fileURLWithPath: path))
            print("✓ \(folder.path): \(try catalog.scan(folderID: folder.id).summary)")
        }
    case "scan":
        print(try catalog.scanAll().summary)
    case "photos":
        let states = try catalog.exportStates()
        for p in try catalog.photos() {
            let state = switch states[p.id] {
            case .needsReexport: "要再書き出し"
            case .upToDate: "書き出し済み"
            default: "未書き出し"
            }
            let versions = try catalog.versions(photoID: p.id).map(\.name).joined(separator: ", ")
            print("\(p.isMissing ? "⚠︎ 見つからない " : "")\(p.path)\n    [\(versions)]  \(state)")
        }
    case "export":
        let o = try parse(rest)
        for url in o.files {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard let photo = try catalog.photo(path: path) else {
                print("✗ ライブラリに未登録: \(url.path)"); continue
            }
            for v in try catalog.versions(photoID: photo.id) {
                let r = try catalog.export(photo: photo, version: v, format: o.format)
                print("✓ [\(v.name)] → \(r.url.path)  (\(r.decoderID))")
            }
        }
    default:
        print(usage); exit(1)
    }
}

let args = CommandLine.arguments.dropFirst()
do {
    guard let command = args.first else { print(usage); exit(1) }
    if command == "library" {
        try library(args.dropFirst())
        exit(0)
    }
    let o = try parse(args.dropFirst())
    switch command {
    case "decoders":
        for d in DecoderRegistry.all { print("\(d.id.padding(toLength: 10, withPad: " ", startingAt: 0)) \(d.displayName)") }
    case "info":
        for f in o.files { try printInfo(f) }
    case "develop":
        try develop(o)
    case "wb":
        // rawlab wb <file> <x> <y>  … 点 (x, y は 0〜1、左上原点) が無彩色になる色温度・色かぶり
        guard o.files.count == 3, let x = Double(o.files[1].lastPathComponent),
              let y = Double(o.files[2].lastPathComponent) else { print(usage); exit(1) }
        var opts = o.decode
        opts.halfSize = true
        let d = try DecoderRegistry.decode(o.files[0], preferred: o.decoder, options: opts)
        guard let base = DevelopPipeline.materialize(d.image, maxPixel: 2400),
              let r = DevelopPipeline.solveWhiteBalance(base, at: CGPoint(x: x, y: y),
                                                        temperatureRange: -5000...5000, tintRange: -60...60)
        else { print("この点では決められません"); exit(1) }
        print(String(format: "色温度 %+.0f K / 色かぶり %+.1f  (%@)", r.temperature, r.tint, d.decoderID))
        if let p = DevelopPipeline.samplePoint(base, at: CGPoint(x: x, y: y)) {
            let (r0, g0, b0) = DevelopPipeline.rgb(p)
            let (r1, g1, b1) = DevelopPipeline.rgb(DevelopPipeline.whiteBalance(p, temperature: r.temperature, tint: r.tint))
            print(String(format: "  補正前 R %.3f G %.3f B %.3f → 補正後 R %.3f G %.3f B %.3f", r0, g0, b0, r1, g1, b1))
        }
    case "compare":
        try compare(o)
    default:
        print(usage); exit(1)
    }
} catch {
    FileHandle.standardError.write(Data("エラー: \(error.localizedDescription)\n".utf8))
    exit(1)
}
