import AppKit

/// 讓其他 App 的「在 Finder 中顯示」轉到 LiriOS。
/// 做法是全域偏好 `NSFileViewer`:NSWorkspace 的 selectFile / activateFileViewerSelecting / `open -R` 會改交給這個 App。
///
/// 限制(macOS 的規定,無法繞過):
/// - 「開啟資料夾」(例如 `open 資料夾`、NSWorkspace.open(資料夾))永遠由 Finder 處理;
///   系統不允許任何 App 成為 public.folder 的預設 App(會回傳 -50)。
/// - 直接對 Finder 下 AppleScript 的程式不會被轉走。
/// - 已經在執行的 App 會快取舊偏好值,必須用 ⌘Q 完整結束再開啟才會生效。
@MainActor
enum FileViewerIntegration {
    private static let key = "NSFileViewer" as CFString

    static var currentViewer: String? {
        CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
    }

    static var isEnabled: Bool { currentViewer == Bundle.main.bundleIdentifier }

    static func enableWithConfirmation() {
        let alert = NSAlert()
        alert.messageText = String(localized: "要把 LiriOS 設為預設的檔案檢視器嗎?")
        alert.informativeText = String(localized: """
        其他 App(例如 Claude)的「在 Finder 中顯示」會改成在 LiriOS 裡顯示。

        不受影響的部分:桌面、Spotlight、「開啟資料夾」(系統規定一律由 Finder 處理),以及直接呼叫 Finder 的功能。

        設定後,已經開著的 App 需要用 ⌘Q 完整結束再開啟才會生效。LiriOS 也要一直保持安裝在「應用程式」資料夾。
        隨時可以用選單「系統整合 › 還原為 Finder」改回來。
        """)
        alert.addButton(withTitle: String(localized: "設定"))
        alert.addButton(withTitle: String(localized: "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setViewer(Bundle.main.bundleIdentifier)
    }

    static func disable() { setViewer(nil) }

    private static func setViewer(_ bundleID: String?) {
        CFPreferencesSetValue(key, bundleID as CFString?, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}
