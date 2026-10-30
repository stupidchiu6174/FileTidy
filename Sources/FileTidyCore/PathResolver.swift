import Foundation

/// 把使用者輸入的路徑(可能不完整、大小寫不對、少了開頭)解析成實際存在的位置。
/// 例如 "/downloads" → ~/Downloads、"~/doc" → ~/Documents、"desktop/專案" → ~/Desktop/專案。
public enum PathResolver {
    /// 看起來像路徑的輸入(以 / 或 ~ 開頭、或含有 /),搜尋框才會嘗試解析成位置。
    public static func looksLikePath(_ input: String) -> Bool {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.hasPrefix("~") || s.contains("/")
    }

    /// 依序嘗試:原樣(根目錄)→ 個人資料夾 → 目前資料夾。每一層先找完全相符,
    /// 再找不分大小寫/本地化名稱(例如「下載項目」);都找不到時才接受唯一的開頭相符("/down")。
    public static func resolve(_ input: String, relativeTo base: URL? = nil,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2, let f = s.first, let l = s.last, f == l, f == "\"" || f == "'" { s = String(s.dropFirst().dropLast()) }
        if s.hasPrefix("file://"), let u = URL(string: s) { s = u.path }
        guard !s.isEmpty else { return nil }

        var roots: [URL] = []
        var rest = s
        if s == "~" || s.hasPrefix("~/") {
            roots = [home]
            rest = String(s.dropFirst())
        } else if s.hasPrefix("/") {
            roots = [URL(fileURLWithPath: "/"), home]
            if let base { roots.append(base) }
        } else {
            if let base { roots.append(base) }
            roots += [home, URL(fileURLWithPath: "/")]
        }
        let components = rest.split(separator: "/").map(String.init)

        var seen = Set<String>()
        roots = roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
        for allowPrefix in [false, true] {
            for root in roots {
                if let u = walk(root, components, allowPrefix: allowPrefix) { return u }
            }
        }
        return nil
    }

    private static func walk(_ root: URL, _ components: [String], allowPrefix: Bool) -> URL? {
        var cur = root.standardizedFileURL
        for c in components {
            switch c {
            case ".": continue
            case "..": cur.deleteLastPathComponent(); continue
            default: break
            }
            guard let next = child(of: cur, named: c, allowPrefix: allowPrefix) else { return nil }
            cur = next
        }
        return FileManager.default.fileExists(atPath: cur.path) ? cur : nil
    }

    private static func child(of dir: URL, named name: String, allowPrefix: Bool) -> URL? {
        let fm = FileManager.default
        let exact = dir.appendingPathComponent(name)
        // 檔案系統不分大小寫時 fileExists 也會成立,改用實際列出的名稱,讓顯示的路徑大小寫正確
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else {
            return fm.fileExists(atPath: exact.path) ? exact : nil
        }
        if names.contains(name) { return exact }
        let key = fold(name)
        if let n = names.first(where: { fold($0) == key }) { return dir.appendingPathComponent(n) }
        if let n = names.first(where: { fold(fm.displayName(atPath: dir.appendingPathComponent($0).path)) == key }) {
            return dir.appendingPathComponent(n)
        }
        guard allowPrefix else { return nil }
        let prefixed = names.filter { !$0.hasPrefix(".") && fold($0).hasPrefix(key) }
        if prefixed.count == 1 { return dir.appendingPathComponent(prefixed[0]) }
        return nil
    }

    private static func fold(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }
}
