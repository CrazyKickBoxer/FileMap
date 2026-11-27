import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        if HeadlessCommands.run(CommandLine.arguments) { return }
        FileMapApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (@MainActor () -> Void)?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { onTerminate?() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct FileMapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup("FileMap", id: "main") {
            ContentView(app: app)
                .frame(minWidth: 820, minHeight: 560)
                .onAppear { delegate.onTerminate = { [app] in app.willTerminate() } }
        }
        .windowToolbarStyle(.unified)
        .commands { FileMapCommands(app: app) }

        Settings {
            SettingsView(app: app)
        }
    }
}
