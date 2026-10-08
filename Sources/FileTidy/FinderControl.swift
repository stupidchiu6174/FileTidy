import AppKit

/// 把 Finder 隱藏起來(等同在 Finder 按 ⌘H)。
/// 這只是隱藏它的視窗,不會結束 Finder,也不改任何系統設定;點 Dock 裡的 Finder 圖示就會回來。
/// 桌面上的圖示是 Finder 畫的,隱藏 Finder 不會讓它們消失。
@MainActor
enum FinderControl {
    private static let finderID = "com.apple.finder"
    private static let key = "hideFinderOnLaunch"

    static var app: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: finderID).first
    }

    static var isHidden: Bool { app?.isHidden ?? false }

    @discardableResult
    static func hide() -> Bool { app?.hide() ?? false }

    static var hideOnLaunch: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
