// swift-tools-version: 6.0
import Foundation
import PackageDescription

/// rawler-ffi の静的ライブラリ(先に `cargo build --release` が必要)
let rawlerLib = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("rawler-ffi/target/release").path

let package = Package(
    name: "RawLab",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DecoderKit", targets: ["DecoderKit"]),
        .library(name: "LibraryKit", targets: ["LibraryKit"]),
        .executable(name: "rawlab", targets: ["rawlab"]),
        .executable(name: "RawLabApp", targets: ["RawLabApp"]),
    ],
    targets: [
        // Homebrew の LibRaw (brew install libraw) をそのまま使う。自分用なので動的リンクで OK。
        .systemLibrary(name: "CLibRaw", path: "Sources/CLibRaw"),
        // Rust の rawler を C ABI 経由で使う
        .systemLibrary(name: "CRawler", path: "Sources/CRawler"),
        .target(
            name: "DecoderKit",
            dependencies: ["CLibRaw", "CRawler"],
            linkerSettings: [.unsafeFlags(["-L/opt/homebrew/opt/libraw/lib", "-L\(rawlerLib)"])]
        ),
        // RAW の場所・現像バージョン・書き出し履歴を SQLite で管理する
        .target(
            name: "LibraryKit",
            dependencies: ["DecoderKit"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "rawlab", dependencies: ["DecoderKit", "LibraryKit"], path: "Sources/rawlab-cli"),
        .executableTarget(name: "RawLabApp", dependencies: ["DecoderKit", "LibraryKit"]),
    ],
    swiftLanguageModes: [.v5]
)
