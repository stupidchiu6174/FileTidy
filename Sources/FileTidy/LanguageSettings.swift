import AppKit

/// App 內的語言切換。macOS 會依 `AppleLanguages` 決定這個 App 使用哪種語言;
/// 寫入 App 自己的設定就能覆蓋系統語言,移除則跟隨系統。需要重新啟動才會套用。
@MainActor
enum LanguageSettings {
    struct Option: Identifiable {
        let code: String?       // nil = 跟隨系統
        let nativeName: String  // 各語言用自己的名字顯示,不翻譯
        var id: String { code ?? "system" }
    }

    static let options: [Option] = [
        Option(code: nil, nativeName: ""),
        Option(code: "zh-Hant", nativeName: "繁體中文"),
        Option(code: "en", nativeName: "English"),
        Option(code: "ja", nativeName: "日本語"),
    ]

    /// 目前 App 層級的語言覆蓋(沒有覆蓋時回傳 nil)
    static var override: String? {
        guard let id = Bundle.main.bundleIdentifier,
              let langs = UserDefaults.standard.persistentDomain(forName: id)?["AppleLanguages"] as? [String] else { return nil }
        return langs.first
    }

    static func isSelected(_ code: String?) -> Bool {
        guard let current = override else { return code == nil }
        guard let code else { return false }
        return current.hasPrefix(code)
    }

    static func set(_ code: String?) {
        if let code { UserDefaults.standard.set([code], forKey: "AppleLanguages") }
        else { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        UserDefaults.standard.synchronize()

        let alert = NSAlert()
        alert.messageText = String(localized: "要重新啟動 LiriOS 才能切換語言")
        alert.informativeText = String(localized: "重新啟動後會使用新的語言。")
        alert.addButton(withTitle: String(localized: "重新啟動"))
        alert.addButton(withTitle: String(localized: "稍後"))
        if alert.runModal() == .alertFirstButtonReturn { relaunch() }
    }

    /// 等目前的程序結束後再開新的一個(同一個 App 直接 open 只會把舊的帶到前景)
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.8; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
