import AppKit
import SwiftUI

@main
struct RawLabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("RawLab") {
            ContentView(model: model)
                .frame(minWidth: 1280, minHeight: 720)
                .onAppear { model.start() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("フォルダをライブラリに追加…") { model.addFolder() }
                    .keyboardShortcut("o")
                Button("すべてのフォルダを再スキャン") { model.rescanAll() }
                    .keyboardShortcut("r")
            }
            CommandGroup(before: .toolbar) {
                Button(model.isZoomed ? "全体を表示" : "等倍で表示") { model.toggleZoom() }
                    .keyboardShortcut("1")
                    .disabled(model.selectedPhoto == nil)
                Divider()
            }
        }
    }
}

/// SwiftPM の実行ファイルは .app バンドルではないので、普通のアプリとして前面に出す
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
