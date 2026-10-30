import SwiftUI
import FileTidy

/// 單獨執行檔案管理視窗
@main
struct FileTidyApp: App {
    @NSApplicationDelegateAdaptor(Delegate.self) private var delegate

    var body: some Scene { FileTidyWindow() }

    final class Delegate: NSObject, NSApplicationDelegate {
        func applicationDidFinishLaunching(_ notification: Notification) {
            FileTidyIntegration.didFinishLaunching()
        }

        func application(_ application: NSApplication, open urls: [URL]) {
            FileTidyIntegration.open(urls)
        }
    }
}
