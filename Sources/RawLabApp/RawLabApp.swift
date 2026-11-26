import AppKit
import SwiftUI

@main
struct RawLabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("RawLab") {
            ContentView(model: model)
                .frame(minWidth: 1100, minHeight: 680)
                .onAppear { model.openInitialFolder() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("フォルダを開く…") { model.openFolder() }
                    .keyboardShortcut("o")
                Button("書き出し…") { model.export() }
                    .keyboardShortcut("e")
                    .disabled(model.selection == nil)
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
