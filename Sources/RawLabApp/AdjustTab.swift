import DecoderKit
import Foundation

/// 下のパネルのタブ。補正項目 + デコーダー
enum AdjustTab: String, CaseIterable, Identifiable, Hashable {
    case exposure, whiteBalance, channelExposure, contrast, highlights, rolloff, shadows, tone, vibrance, saturation
    case noiseReduction, sharpness
    case decoder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .exposure: "露出"
        case .whiteBalance: "ホワイトバランス"
        case .channelExposure: "色ごとの露出"
        case .contrast: "コントラスト"
        case .highlights: "ハイライト"
        case .rolloff: "ハイライト圧縮"
        case .shadows: "シャドウ"
        case .tone: "レベル・カーブ"
        case .vibrance: "自然な彩度"
        case .saturation: "彩度"
        case .noiseReduction: "ノイズ低減"
        case .sharpness: "シャープ"
        case .decoder: "デコーダー"
        }
    }

    /// ホワイトバランスは 2 方向のマス目(横: 色温度 9 段階、縦: 色かぶり 3 段階)
    var grid: (x: AdjustParam, y: AdjustParam)? {
        guard self == .whiteBalance else { return nil }
        return (AdjustParam(\.temperature, -5000...5000, coarse: 1000, fine: 100, format: "%+.0f K", count: 9),
                AdjustParam(\.tint, -60...60, coarse: 12, fine: 4, format: "%+.0f", count: 3))
    }

    /// 色ごとの露出: R・G・B の 3 段(それぞれ独立に選ぶ)
    var channelParams: [AdjustParam]? {
        guard self == .channelExposure else { return nil }
        return [\DevelopSettings.exposureR, \.exposureG, \.exposureB].map {
            AdjustParam($0, -1...1, coarse: 0.2, fine: 0.05, format: "%+.2f")
        }
    }

    /// レベル補正・トーンカーブはサムネイルではなく専用の編集画面(1 つのタブに並べる)
    var isToneEditor: Bool { self == .tone }

    /// デコーダー・ホワイトバランス・レベル補正・トーンカーブは nil
    var param: AdjustParam? {
        switch self {
        case .exposure: AdjustParam(\.exposure, -2.5...2.5, coarse: 0.5, fine: 0.1, format: "%+.1f EV")
        case .contrast: AdjustParam(\.contrast, -1...1, coarse: 0.2, fine: 0.04, format: "%+.2f")
        case .highlights: AdjustParam(\.highlights, 0...1, coarse: 0.1, fine: 0.02, format: "%.2f")
        case .rolloff: AdjustParam(\.highlightRolloff, 0...1, coarse: 0.1, fine: 0.02, format: "%.2f")
        case .shadows: AdjustParam(\.shadows, -1...1, coarse: 0.2, fine: 0.04, format: "%+.2f")
        case .vibrance: AdjustParam(\.vibrance, -1...1, coarse: 0.2, fine: 0.04, format: "%+.2f")
        case .saturation: AdjustParam(\.saturation, -1...1, coarse: 0.2, fine: 0.04, format: "%+.2f")
        case .noiseReduction: AdjustParam(\.noiseReduction, 0...1, coarse: 0.1, fine: 0.02, format: "%.2f", usesCrop: true)
        case .sharpness: AdjustParam(\.sharpness, 0...1, coarse: 0.1, fine: 0.02, format: "%.2f", usesCrop: true)
        case .whiteBalance, .channelExposure, .tone, .decoder: nil
        }
    }
}

/// 1 つの補正項目の段階の作り方。
/// 粗い 11 段階(範囲全体)→ 選ぶと、その値を中心にした細かい 11 段階に切り替わる。
struct AdjustParam: @unchecked Sendable {
    /// 並べる段階の数
    let count: Int

    let keyPath: WritableKeyPath<DevelopSettings, Double>
    let range: ClosedRange<Double>
    let coarseStep: Double
    let fineStep: Double
    let format: String
    /// ノイズ低減・シャープは縮小すると差が見えないので等倍で切り出す
    let usesCrop: Bool

    init(_ keyPath: WritableKeyPath<DevelopSettings, Double>, _ range: ClosedRange<Double>,
         coarse: Double, fine: Double, format: String, usesCrop: Bool = false, count: Int = 11) {
        self.count = count
        self.keyPath = keyPath
        self.range = range
        self.coarseStep = coarse
        self.fineStep = fine
        self.format = format
        self.usesCrop = usesCrop
    }

    /// 範囲がマイナスを含むなら 0 を真ん中に、そうでなければ下限から並べる
    var coarseValues: [Double] {
        let start = range.lowerBound < 0 ? -Double(count / 2) * coarseStep : range.lowerBound
        return (0..<count).map { round(start + Double($0) * coarseStep) }
    }

    /// 今の値を真ん中にした細かい段階。範囲の端ではずらして 11 個そろえる
    func fineValues(around value: Double) -> [Double] {
        let half = Double(count / 2) * fineStep
        let start = min(max(value - half, range.lowerBound), range.upperBound - 2 * half)
        return (0..<count).map { round(start + Double($0) * fineStep) }
    }

    func clamp(_ v: Double) -> Double { round(min(max(v, range.lowerBound), range.upperBound)) }

    /// 浮動小数の誤差を細かい刻みに合わせて丸める
    func round(_ v: Double) -> Double { (v / fineStep).rounded() * fineStep }

    func label(_ v: Double) -> String {
        // 0 のときは「+0.0」ではなく「0.0」
        abs(v) < fineStep / 2
            ? String(format: format, 0.0).replacingOccurrences(of: "+", with: "")
            : String(format: format, v)
    }
}
