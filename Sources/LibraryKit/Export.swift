import DecoderKit
import Foundation

extension Catalog {
    /// 書き出し先: <書き出しルート>/<撮影年>/<撮影日>/<撮影日時>_<RAW名>[_<バージョン名>].<拡張子>
    /// 最初のバージョンは名前を付けない。同じバージョンの再書き出しは上書き、他のファイルとぶつかったら連番。
    public func exportDestination(photo: Photo, version: DevelopVersion, format: ExportFormat) throws -> URL {
        let date = photo.captureDate
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        var folder = exportRoot
        if let date {
            day.dateFormat = "yyyy"
            folder.appendPathComponent(day.string(from: date))
            day.dateFormat = "yyyy-MM-dd"
            folder.appendPathComponent(day.string(from: date))
        } else {
            folder.appendPathComponent("撮影日不明")
        }

        var base = photo.url.deletingPathExtension().lastPathComponent
        if let date {
            day.dateFormat = "yyyyMMdd_HHmmss"
            base = "\(day.string(from: date))_\(base)"
        }
        let isFirstVersion = try versions(photoID: photo.id).first?.id == version.id
        if !isFirstVersion {
            base += "_" + Self.sanitize(version.name)
        }

        var candidate = folder.appendingPathComponent(base).appendingPathExtension(format.fileExtension)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path),
              try !isExportPath(candidate, of: version.id) {
            candidate = folder.appendingPathComponent("\(base)-\(n)").appendingPathExtension(format.fileExtension)
            n += 1
        }
        return candidate
    }

    /// フル解像度で現像して書き出し、履歴を残す
    @discardableResult
    public func export(photo: Photo, version: DevelopVersion, format: ExportFormat,
                       quality: Double = 0.92) throws -> (url: URL, decoderID: String) {
        let dest = try exportDestination(photo: photo, version: version, format: format)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var options = version.decodeOptions
        options.halfSize = false
        let decoded = try DecoderRegistry.decode(photo.url, preferred: version.decoderID, options: options)
        let image = DevelopPipeline.apply(version.settings, to: decoded.image)
        try Exporter.export(image, to: dest, format: format, quality: quality)
        try recordExport(versionID: version.id, url: dest, format: format, hash: version.contentHash)
        return (dest, decoded.decoderID)
    }

    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines)
        return name.components(separatedBy: bad).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
    }
}
