import Foundation

/// 側邊欄「位置」區的一個項目:系統預設位置(可隱藏),或使用者自己加的資料夾。
public struct SidebarEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// 預設位置的代號(home、desktop…);自訂資料夾為 nil
    public var builtin: String?
    /// 自訂資料夾的路徑
    public var path: String?
    /// 自訂的顯示名稱(只改側邊欄上的名字,不會改磁碟上的資料夾)
    public var title: String?
    /// 自訂的圖示(SF Symbols 名稱)
    public var symbol: String?
    /// 預設位置被「移除」時只是隱藏,之後能在自訂畫面裡重新打開
    public var hidden: Bool

    public init(id: UUID = UUID(), builtin: String? = nil, path: String? = nil, title: String? = nil,
                symbol: String? = nil, hidden: Bool = false) {
        self.id = id; self.builtin = builtin; self.path = path; self.title = title; self.symbol = symbol; self.hidden = hidden
    }

    public var isCustomFolder: Bool { builtin == nil }
    public var isCustomized: Bool { title != nil || symbol != nil }
}

public struct SidebarLayout: Codable, Equatable, Sendable {
    public var entries: [SidebarEntry]
    public var showVolumes = true
    public var showTools = true

    public static let builtinIDs = ["home", "desktop", "documents", "downloads", "pictures", "movies", "music", "applications", "trash"]

    public init(entries: [SidebarEntry], showVolumes: Bool = true, showTools: Bool = true) {
        self.entries = entries
        self.showVolumes = showVolumes
        self.showTools = showTools
        normalize()
    }

    public static var defaults: SidebarLayout {
        SidebarLayout(entries: builtinIDs.map { SidebarEntry(builtin: $0) })
    }

    public var visibleEntries: [SidebarEntry] { entries.filter { !$0.hidden } }

    /// 保證每個預設位置都在清單裡且只出現一次(日後新增預設位置時,舊的設定也能補上)
    public mutating func normalize() {
        var seen = Set<String>()
        entries = entries.filter { e in
            guard let b = e.builtin else { return true }
            guard Self.builtinIDs.contains(b), !seen.contains(b) else { return false }
            seen.insert(b); return true
        }
        for b in Self.builtinIDs where !seen.contains(b) { entries.append(SidebarEntry(builtin: b, hidden: true)) }
    }

    public enum AddResult: Equatable {
        case added(UUID)
        case alreadyThere(UUID)   // 已經在側邊欄上
        case revealedBuiltin(UUID) // 這個資料夾其實是某個預設位置,把它重新打開
    }

    /// 加入資料夾。`builtinPaths` 是「預設位置代號 → 實際路徑」,用來避免重複加入桌面、下載這類預設位置。
    @discardableResult
    public mutating func addFolder(_ path: String, title: String? = nil, builtinPaths: [String: String] = [:]) -> AddResult {
        let target = Self.normalizedPath(path)
        if let (id, _) = builtinPaths.first(where: { Self.normalizedPath($0.value) == target }),
           let i = entries.firstIndex(where: { $0.builtin == id }) {
            let wasHidden = entries[i].hidden
            entries[i].hidden = false
            return wasHidden ? .revealedBuiltin(entries[i].id) : .alreadyThere(entries[i].id)
        }
        if let existing = entries.first(where: { $0.path.map(Self.normalizedPath) == target }) {
            return .alreadyThere(existing.id)
        }
        let entry = SidebarEntry(path: target, title: title)
        entries.append(entry)
        return .added(entry.id)
    }

    /// 移除:預設位置只隱藏,自訂資料夾直接刪除
    public mutating func remove(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        if entries[i].isCustomFolder { entries.remove(at: i) } else { entries[i].hidden = true }
    }

    public mutating func setHidden(_ id: UUID, _ hidden: Bool) {
        if let i = entries.firstIndex(where: { $0.id == id }) { entries[i].hidden = hidden }
    }

    /// 改名稱與圖示;傳 nil 或空字串表示還原成預設
    public mutating func customize(_ id: UUID, title: String?, symbol: String?) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        entries[i].title = (t?.isEmpty ?? true) ? nil : t
        entries[i].symbol = (symbol?.isEmpty ?? true) ? nil : symbol
    }

    /// 在「目前看得到的項目」上拖曳排序(側邊欄);被隱藏的項目維持原位。
    public mutating func moveVisible(from source: IndexSet, to destination: Int) {
        let slots = entries.indices.filter { !entries[$0].hidden }
        var visible = slots.map { entries[$0] }
        Self.move(&visible, from: source, to: destination)
        for (k, slot) in slots.enumerated() { entries[slot] = visible[k] }
    }

    /// 側邊欄上「實際顯示」的項目(依顯示順序傳入 ID)被拖曳排序;沒顯示的項目維持原位。
    public mutating func moveShown(_ shown: [UUID], from source: IndexSet, to destination: Int) {
        let shownSet = Set(shown)
        let slots = entries.indices.filter { shownSet.contains(entries[$0].id) }
        var ordered = shown.compactMap { id in entries.first { $0.id == id } }
        guard ordered.count == slots.count else { return }
        Self.move(&ordered, from: source, to: destination)
        for (k, slot) in slots.enumerated() { entries[slot] = ordered[k] }
    }

    /// 在完整清單(含隱藏項目)上排序(自訂畫面)
    public mutating func move(from source: IndexSet, to destination: Int) {
        Self.move(&entries, from: source, to: destination)
    }

    public mutating func restoreDefaults() { self = .defaults }

    /// 與 SwiftUI `onMove` 相同語意的搬移(`destination` 是搬移前的插入位置)
    static func move<T>(_ array: inout [T], from source: IndexSet, to destination: Int) {
        let moving = source.sorted().map { array[$0] }
        let before = source.filter { $0 < destination }.count
        for i in source.sorted(by: >) { array.remove(at: i) }
        array.insert(contentsOf: moving, at: min(max(destination - before, 0), array.count))
    }

    static func normalizedPath(_ p: String) -> String {
        var s = URL(fileURLWithPath: p).standardizedFileURL.path
        if s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
