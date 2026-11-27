import Foundation

/// カメラごとの色の値(XYZ → カメラの RGB の行列)と、そこから求める変換。
enum CameraColor {
    /// DNG の ColorMatrix2(D65 光源)相当の値 × 10000。
    /// キーは EXIF の Model(大文字)。
    ///
    /// 出典: Adobe DNG Converter が NEF を DNG にするときに書く ColorMatrix2。
    /// dcraw の adobe_coeff() と LibRaw の colordata(src/tables/colordata.cpp)にも
    /// 同じ値が載っている(LibRaw 0.22.3 が D5_sample.NEF で返す cam_xyz と一致することを確認済み)。
    static let matrices: [String: [Double]] = [
        "NIKON D5": [9200, -3522, -992, -5755, 13803, 2117, -753, 1486, 6338],
    ]

    static var supportedModels: [String] { matrices.keys.sorted() }

    /// リニア sRGB(D65)→ XYZ
    private static let xyzFromSRGB: [Double] = [
        0.412453, 0.357580, 0.180423,
        0.212671, 0.715160, 0.072169,
        0.019334, 0.119193, 0.950227,
    ]

    /// XYZ → カメラの行列から、
    /// - ホワイトバランス後のカメラの RGB → リニア sRGB の行列(3×3、行ごと)
    /// - 昼光(D65)の WB 係数(緑 = 1)
    /// を求める(dcraw の cam_xyz_coeff と同じ考え方)。
    ///
    /// sRGB → カメラの行列の各行を合計 1 にそろえると、白(1,1,1)が白に写るようになる。
    /// そろえる前の行の合計の逆数が、昼光でカメラの RGB を白にそろえる WB 係数になる。
    static func conversion(cameraFromXYZ m: [Double]) -> (matrix: [Float], daylight: [Float])? {
        guard m.count == 9 else { return nil }
        let camXYZ = m.map { $0 / 10000 }
        var camRGB = multiply(camXYZ, xyzFromSRGB)
        var daylight = [Double](repeating: 1, count: 3)
        for i in 0..<3 {
            let sum = camRGB[i * 3] + camRGB[i * 3 + 1] + camRGB[i * 3 + 2]
            guard sum > 0 else { return nil }
            for j in 0..<3 { camRGB[i * 3 + j] /= sum }
            daylight[i] = 1 / sum
        }
        guard let rgbCam = invert(camRGB) else { return nil }
        return (rgbCam.map(Float.init), daylight.map { Float($0 / daylight[1]) })
    }

    private static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        (0..<3).flatMap { i in
            (0..<3).map { j in (0..<3).reduce(0) { $0 + a[i * 3 + $1] * b[$1 * 3 + j] } }
        }
    }

    private static func invert(_ m: [Double]) -> [Double]? {
        let det = m[0] * (m[4] * m[8] - m[5] * m[7])
            - m[1] * (m[3] * m[8] - m[5] * m[6])
            + m[2] * (m[3] * m[7] - m[4] * m[6])
        guard abs(det) > 1e-12 else { return nil }
        let c: [Double] = [
            m[4] * m[8] - m[5] * m[7], m[2] * m[7] - m[1] * m[8], m[1] * m[5] - m[2] * m[4],
            m[5] * m[6] - m[3] * m[8], m[0] * m[8] - m[2] * m[6], m[2] * m[3] - m[0] * m[5],
            m[3] * m[7] - m[4] * m[6], m[1] * m[6] - m[0] * m[7], m[0] * m[4] - m[1] * m[3],
        ]
        return c.map { $0 / det }
    }
}
