import SwiftUI
import AppKit
import ServiceManagement
import Quartz
import FileTidyCore

enum Mode: String, CaseIterable, Identifiable, Hashable {
    case browse, organize, duplicates, rename, disk, history

    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .browse: "瀏覽"
        case .organize: "自動分類"
        case .duplicates: "重複檔案"
        case .rename: "批次改名"
        case .disk: "空間分析"
        case .history: "操作紀錄"
        }
    }
    var icon: String {
        switch self {
        case .browse: "folder"
        case .organize: "folder.badge.gearshape"
        case .duplicates: "doc.on.doc"
        case .rename: "pencil.line"
        case .disk: "chart.bar.xaxis"
        case .history: "arrow.uturn.backward.circle"
        }
    }
    static var tools: [Mode] { [.organize, .duplicates, .rename, .disk, .history] }
}

/// 瀏覽資料夾時的顯示方式(與 Finder 相同的四種,順序也一樣)
enum ViewMode: String, CaseIterable, Identifiable {
    case icons, list, columns, gallery

    var id: String { rawValue }
    var symbol: String {
        switch self { case .icons: "square.grid.2x2"; case .list: "list.bullet"; case .columns: "rectangle.split.3x1"; case .gallery: "rectangle.grid.1x2" }
    }
    var title: LocalizedStringKey {
        switch self { case .icons: "圖示"; case .list: "列表"; case .columns: "欄"; case .gallery: "圖庫" }
    }
}

/// 圖示模式下的圖示大小
enum IconSize: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }
    var points: CGFloat { switch self { case .small: 36; case .medium: 56; case .large: 88 } }
    var title: LocalizedStringKey { switch self { case .small: "小"; case .medium: "中"; case .large: "大" } }
}

struct Place: Identifiable, Hashable {
    let name: String
    let icon: String
    let url: URL
    /// 對應的側邊欄設定項目(系統自動列出的磁碟沒有)
    var entryID: UUID? = nil
    /// 自訂資料夾已經不存在(被刪除、磁碟沒接上)
    var missing = false
    var id: URL { url }
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    // 瀏覽
    var tabs: [BrowserTab]
    var activeID: UUID
    var mode: Mode = .browse { didSet { if mode != oldValue { clearPlan(); generation += 1 } } }
    var showHidden = false
    var sidebar: SidebarLayout = SidebarStore.load() {
        didSet { SidebarStore.save(sidebar) }
    }
    var sidebarEditTarget: SidebarEditRequest?
    var showSidebarCustomize = false
    var viewMode: ViewMode = AppModel.storedViewMode().mode {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode") }
    }
    var iconSize: IconSize = AppModel.storedViewMode().size {
        didSet { UserDefaults.standard.set(iconSize.rawValue, forKey: "iconSize") }
    }

    /// 讀取設定。舊版的 large/medium/small 轉成「圖示 + 大小」
    private static func storedViewMode() -> (mode: ViewMode, size: IconSize) {
        let raw = UserDefaults.standard.string(forKey: "viewMode") ?? ""
        let savedSize = IconSize(rawValue: UserDefaults.standard.string(forKey: "iconSize") ?? "") ?? .medium
        if let legacy = IconSize(rawValue: raw) { return (.icons, legacy) }
        return (ViewMode(rawValue: raw) ?? .list, savedSize)
    }

    // 全域搜尋
    var query = ""
    var searchAllMac = true
    var hits: [SearchHit] = []
    var searching = false
    var searchSelection = Set<String>()
    var searchAnchor: String?
    var focusSearchTick = 0
    /// 搜尋框輸入像路徑("/downloads"、"~/doc")且找得到對應位置時,顯示「前往」的建議
    var pathMatch: URL?
    var showGoToFolder = false

    // 目錄
    let catalog = FileCatalog()
    var phase: CatalogPhase = .idle
    private var searchTask: Task<Void, Never>?

    // 計畫 / 紀錄
    var plan: OperationPlan?
    var selected = Set<UUID>()
    var confirmApply = false
    let journal = Journal()
    var history: [JournalEntry] = []
    var status = ""
    var generation = 0
    var busy = false
    /// 彈簧資料夾:拖曳中停留的資料夾與計時器
    @ObservationIgnored var springTarget: URL?
    @ObservationIgnored var springTimer: Timer?

    // 對話框
    var renameTarget: URL?
    /// 圖示檢視裡直接在檔名上編輯(雙擊檔名)
    var inlineRenameTarget: URL?
    var infoTarget: URL?
    var analysisTarget: AnalysisRequest?
    var launchAtLogin = SMAppService.mainApp.status == .enabled
    var hideFinderOnLaunch = FinderControl.hideOnLaunch {
        didSet { FinderControl.hideOnLaunch = hideFinderOnLaunch; if hideFinderOnLaunch { FinderControl.hide() } }
    }
    var hideAtLogin = UserDefaults.standard.bool(forKey: FileTidyIntegration.hideAtLoginKey) {
        didSet { UserDefaults.standard.set(hideAtLogin, forKey: FileTidyIntegration.hideAtLoginKey) }
    }
    var viewerIsDefault = FileViewerIntegration.isEnabled
    var pendingDelete: [URL]?
    var confirmEmptyTrash = false
    /// 設定後立刻以 Finder 式的面板預覽,然後歸零
    var quickLookURL: URL? {
        didSet { if let u = quickLookURL { quickLookURL = nil; presentQuickLook(u) } }
    }

    init() {
        let first = BrowserTab(url: FileManager.default.homeDirectoryForCurrentUser)
        tabs = [first]
        activeID = first.id
        applySavedSort(to: first)
        history = journal.entries
        Task { await startCatalog() }
        longPress.install { [weak self] in self?.previewSelection() }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIntegration() }
        }
        _ = QLPreviewPanel.shared()  // 預先建立,減少第一次預覽的延遲
    }

    @ObservationIgnored private let longPress = LongPressMonitor()

    private func presentQuickLook(_ url: URL) {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let urls = searching ? hits.map(\.item.url) : tab.sortedItems.map(\.url)
        let ql = QuickLookController.shared
        ql.sourceProvider = { [weak self] u in self?.iconSource(for: u, in: urls) }
        ql.show(urls: urls.contains { $0.path == url.path } ? urls : [url], current: url)
    }

    /// 找出該檔案那一列的圖示在螢幕上的位置,供預覽放大/縮回動畫使用
    private func iconSource(for url: URL, in urls: [URL]) -> (frame: NSRect, image: NSImage?)? {
        // 圖示檢視:從該格的圖示位置放大
        if viewMode == .icons, query.trimmingCharacters(in: .whitespaces).isEmpty,
           let win = FileTidyIntegration.visibleWindow,
           let cell = DragSourceView.find(path: url.path, in: win.contentView!), cell.iconPoints > 0,
           !cell.visibleRect.isEmpty {
            let s = cell.iconPoints
            let b = cell.bounds
            let rect = NSRect(x: b.midX - s / 2, y: cell.isFlipped ? b.minY + 6 : b.maxY - 6 - s, width: s, height: s)
            let screen = win.convertToScreen(cell.convert(rect, to: nil))
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let isPkg = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
            return (screen, Thumbs.cached(url) ?? Icons.icon(url: url, isFolder: isDir && !isPkg, isPackage: isPkg))
        }
        guard let row = urls.firstIndex(where: { $0.path == url.path }),
              let window = FileTidyIntegration.visibleWindow,
              let table = Self.findFileTable(in: window.contentView!), row < table.numberOfRows else { return nil }
        let rowRect = table.rect(ofRow: row)
        guard table.visibleRect.intersects(rowRect) else { return nil }
        let cell = table.frameOfCell(atColumn: 0, row: row)
        let icon = NSRect(x: cell.minX + 4, y: cell.minY + (cell.height - 20) / 2, width: 20, height: 20)
        let inWindow = table.convert(icon, to: nil)
        let screen = window.convertToScreen(inWindow)
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let isPkg = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
        let image = Thumbs.cached(url) ?? Icons.icon(url: url, isFolder: isDir && !isPkg, isPackage: isPkg)
        return (screen, image)
    }

    /// 檔案列表是欄位最多的那個 NSTableView(側邊欄也是 NSTableView,但只有一欄)
    static func findFileTable(in root: NSView) -> NSTableView? {
        var best: NSTableView?
        func walk(_ v: NSView) {
            if let t = v as? NSTableView, t.tableColumns.count >= 3, (best?.tableColumns.count ?? 0) < t.tableColumns.count { best = t }
            v.subviews.forEach(walk)
        }
        walk(root)
        return best
    }

    /// 長按/Force Click 時預覽游標底下那一列(不需要先選取;表格要等放開才更新選取)
    private func previewSelection() {
        guard mode == .browse, renameTarget == nil else { return }
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let urls = searching ? hits.map(\.item.url) : tab.sortedItems.map(\.url)
        if let url = urlUnderCursor(in: urls) {
            // 讓選取狀態也跟上,與 Finder 的行為一致
            if searching { searchSelection = [url.path] } else { tab.selection = [url] }
            quickLookURL = url
        } else if searching, let p = searchSelection.first, searchSelection.count == 1 {
            quickLookURL = URL(fileURLWithPath: p)
        } else if !searching, let u = tab.selection.first, tab.selection.count == 1 {
            quickLookURL = u
        }
    }

    private func urlUnderCursor(in urls: [URL]) -> URL? {
        guard let window = FileTidyIntegration.visibleWindow,
              let content = window.contentView else { return nil }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        if let src = DragSourceView.enclosing(content.hitTest(inWindow)) { return src.url }
        guard let table = Self.findFileTable(in: content) else { return nil }
        let row = table.row(at: table.convert(inWindow, from: nil))
        return (0..<urls.count).contains(row) ? urls[row] : nil
    }

    /// 目前被選取(且只選一個)的項目,用來顯示底部路徑列
    var selectedPathURL: URL? {
        guard mode == .browse else { return nil }
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            return tab.selection.count == 1 ? tab.selection.first : nil
        }
        return searchSelection.count == 1 ? searchSelection.first.map { URL(fileURLWithPath: $0) } : nil
    }

    var tab: BrowserTab { tabs.first { $0.id == activeID } ?? tabs[0] }
    var currentFolder: URL { tab.url }

    // MARK: 目錄

    private func startCatalog() async {
        await catalog.setObservers(
            phase: { [weak self] p in Task { @MainActor in self?.phase = p } },
            change: { [weak self] in Task { @MainActor in self?.catalogChanged() } })
        await catalog.start()
    }

    private func catalogChanged() {
        if !query.isEmpty { runSearch() }
    }

    func rebuildIndex() { Task { await catalog.rebuild() } }

    var phaseText: String {
        switch phase {
        case .idle: return String(localized: "準備中…")
        case .loadingCache: return String(localized: "載入索引…")
        case .crawling(let n): return String(localized: "建立索引中… 已找到 \(n.formatted()) 個項目")
        case .ready(let n): return String(localized: "已索引 \(n.formatted()) 個項目")
        case .embedding(let d, let t): return String(localized: "語意索引 \(d.formatted())/\(t.formatted())")
        }
    }

    // MARK: 搜尋

    func queryChanged() {
        searchTask?.cancel()
        pathMatch = PathResolver.looksLikePath(query) ? PathResolver.resolve(query, relativeTo: currentFolder) : nil
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { hits = []; searching = false; return }
        mode = .browse
        runSearch()
    }

    func runSearch() {
        searchTask?.cancel()
        let q = query, scope = searchAllMac ? nil : currentFolder.path
        searching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 80_000_000)  // 輸入時的短暫防抖
            guard !Task.isCancelled else { return }
            let result = await catalog.search(q, scope: scope)
            guard !Task.isCancelled else { return }
            hits = result
            searching = false
        }
    }

    func clearSearch() { searchTask?.cancel(); query = ""; hits = []; searching = false; pathMatch = nil }

    /// 搜尋框按 Enter:輸入是路徑且找得到時直接前往
    func submitSearch() {
        if let pathMatch { reveal(pathMatch) }
    }

    /// 「前往資料夾」:接受不完整的路徑,資料夾 → 進入;檔案 → 到所在資料夾並選取。
    @discardableResult
    func goToPath(_ text: String) -> Bool {
        guard let url = PathResolver.resolve(text, relativeTo: currentFolder) else { return false }
        reveal(url)
        return true
    }

    private func reveal(_ url: URL) {
        var isDir: ObjCBool = false
        let pkg = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue, !pkg {
            open(url)
        } else {
            open(url.deletingLastPathComponent(), select: url)
        }
    }

    func focusSearch() { focusSearchTick += 1 }

    // MARK: 分頁與導覽

    func open(_ url: URL, select: URL? = nil) {
        mode = .browse
        clearSearch()
        tab.go(url, select: select)
    }

    func newTab(_ url: URL? = nil) {
        let t = BrowserTab(url: url ?? currentFolder)
        applySavedSort(to: t)
        t.showHidden = showHidden
        tabs.append(t)
        activeID = t.id
        mode = .browse
    }

    func closeTab(_ id: UUID) {
        guard tabs.count > 1, let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: i)
        if activeID == id { activeID = tabs[min(i, tabs.count - 1)].id }
    }

    // MARK: 排列方式

    enum SortKey: String, CaseIterable, Identifiable {
        case name, kind, modified, created, size
        var id: String { rawValue }

        var title: String {
            switch self {
            case .name: return String(localized: "名稱")
            case .kind: return String(localized: "種類")
            case .modified: return String(localized: "修改日期")
            case .created: return String(localized: "建立日期")
            case .size: return String(localized: "大小")
            }
        }

        /// 第一次選這個排序時的方向:名稱、種類由 A 到 Z;日期、大小由新到舊、由大到小(和 Finder 一樣)
        var defaultAscending: Bool { self == .name || self == .kind }

        func comparator(ascending: Bool) -> KeyPathComparator<DirItem> {
            let order: SortOrder = ascending ? .forward : .reverse
            switch self {
            case .name: return KeyPathComparator(\DirItem.name, comparator: .localizedStandard, order: order)
            case .kind: return KeyPathComparator(\DirItem.kind, comparator: .localizedStandard, order: order)
            case .modified: return KeyPathComparator(\DirItem.sortModified, order: order)
            case .created: return KeyPathComparator(\DirItem.sortCreated, order: order)
            case .size: return KeyPathComparator(\DirItem.sortSize, order: order)
            }
        }

        /// 列表的欄位標題也會改排序,所以從目前的比較器反推是哪一種
        init?(comparator: KeyPathComparator<DirItem>) {
            switch comparator.keyPath {
            case \DirItem.name: self = .name
            case \DirItem.kind: self = .kind
            case \DirItem.sortModified: self = .modified
            case \DirItem.sortCreated: self = .created
            case \DirItem.sortSize: self = .size
            default: return nil
            }
        }
    }

    private static let sortKeyDefault = "sortKey"
    private static let sortAscendingDefault = "sortAscending"
    private static let foldersFirstDefault = "foldersFirst"

    var sortKey: SortKey { tab.sortOrder.first.flatMap(SortKey.init(comparator:)) ?? .name }
    var sortAscending: Bool { tab.sortOrder.first?.order != .reverse }

    /// 排序(列表模式也可直接點欄位標題)。記住選擇,新分頁沿用。
    /// 再選一次目前的排序 = 反過來排。
    func sort(by key: SortKey, ascending: Bool? = nil) {
        let asc = ascending ?? (key == sortKey ? !sortAscending : key.defaultAscending)
        tab.sortOrder = [key.comparator(ascending: asc)]
        UserDefaults.standard.set(key.rawValue, forKey: Self.sortKeyDefault)
        UserDefaults.standard.set(asc, forKey: Self.sortAscendingDefault)
    }

    func setSortAscending(_ asc: Bool) { sort(by: sortKey, ascending: asc) }

    var foldersFirst: Bool {
        get { tab.foldersFirst }
        set {
            tabs.forEach { $0.foldersFirst = newValue }
            UserDefaults.standard.set(newValue, forKey: Self.foldersFirstDefault)
        }
    }

    /// 新分頁套用上次選的排列方式
    func applySavedSort(to t: BrowserTab) {
        let d = UserDefaults.standard
        if let raw = d.string(forKey: Self.sortKeyDefault), let key = SortKey(rawValue: raw) {
            let asc = d.object(forKey: Self.sortAscendingDefault) as? Bool ?? key.defaultAscending
            t.sortOrder = [key.comparator(ascending: asc)]
        }
        t.foldersFirst = d.object(forKey: Self.foldersFirstDefault) as? Bool ?? true
    }

    func toggleHidden() {
        showHidden.toggle()
        tabs.forEach { $0.showHidden = showHidden }
    }

    /// 雙擊/Enter:資料夾進入,檔案以預設 App 開啟
    func activate(_ url: URL) {
        var isDir: ObjCBool = false
        let pkg = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue, !pkg {
            open(url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: 垃圾桶

    var trashURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true) }

    var isInTrash: Bool {
        let p = currentFolder.standardizedFileURL.path, t = trashURL.standardizedFileURL.path
        return p == t || p.hasPrefix(t + "/")
    }

    /// 由 FileTidy 丟進垃圾桶的項目,知道原本的位置(垃圾桶路徑 → 原路徑)
    private var trashOrigins: [String: String] {
        var map: [String: String] = [:]
        for e in journal.entries where !e.undone { for t in e.trashed { map[t.trash] = t.original } }
        return map
    }

    /// 放回原處;不知道原位置的(不是 FileTidy 丟的)放到桌面
    func putBack(_ urls: [URL]) {
        let origins = trashOrigins
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        var unknown = 0
        let actions: [PlannedAction] = urls.map { u in
            if let orig = origins[u.path] { return PlannedAction(kind: .move, source: u, destination: URL(fileURLWithPath: orig)) }
            unknown += 1
            return PlannedAction(kind: .move, source: u, destination: desktop.appendingPathComponent(u.lastPathComponent))
        }
        perform(OperationPlan(title: String(localized: "放回原處(\(urls.count) 項)"), actions: actions))
        if unknown > 0 { status += String(localized: ";其中 \(unknown) 項不知道原位置,已放到桌面") }
    }

    /// 無法復原。呼叫前必須先經過確認視窗。
    func deletePermanently(_ urls: [URL]) {
        var failed: [String] = []
        for u in urls {
            do { try FileManager.default.removeItem(at: u) } catch { failed.append(u.lastPathComponent) }
        }
        status = failed.isEmpty ? String(localized: "已永久刪除 \(urls.count) 項") : String(localized: "已刪除 \(urls.count - failed.count) 項,\(failed.count) 項失敗:") + failed.prefix(2).joined(separator: String(localized: "、"))
        tab.selection = []
        tab.reload()
    }

    func emptyTrash() {
        let items = (try? FileManager.default.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil, options: [])) ?? []
        deletePermanently(items)
    }

    /// 側邊欄「位置」區要顯示的項目(依使用者的自訂)
    var places: [Place] {
        sidebar.visibleEntries.compactMap { e in
            if let b = e.builtin {
                guard let d = Self.builtinPlace(b, trash: trashURL), FileManager.default.fileExists(atPath: d.url.path) else { return nil }
                return Place(name: e.title ?? d.name, icon: e.symbol ?? d.icon, url: d.url, entryID: e.id)
            }
            guard let path = e.path else { return nil }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let name = e.title ?? (url.path == "/" ? "Macintosh HD" : url.lastPathComponent)
            return Place(name: name, icon: e.symbol ?? "folder", url: url, entryID: e.id,
                         missing: !FileManager.default.fileExists(atPath: path))
        }
    }

    var volumes: [Place] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey],
                                                          options: [.skipHiddenVolumes]) ?? []
        return urls.map { Place(name: (try? $0.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? $0.lastPathComponent,
                                icon: $0.path == "/" ? "internaldrive" : "externaldrive", url: $0) }
    }

    // MARK: 檔案操作(全部可 ⌘Z)

    func perform(_ plan: OperationPlan) {
        guard !plan.actions.isEmpty else { return }
        guard let resolutions = resolveConflicts(plan, selected: Set(plan.actions.map(\.id))) else {
            status = String(localized: "已停止,沒有變更任何檔案")
            return
        }
        let r = Executor.run(plan, resolutions: resolutions, journal: journal)
        history = journal.entries
        status = r.failures.isEmpty ? String(localized: "\(plan.title)完成(⌘Z 可復原)") : String(localized: "\(plan.title):\(r.failures.count) 項失敗 — \(r.failures[0])")
        generation += 1
        tab.reload()
    }

    var selectionURLs: [URL] { Array(tab.selection) }

    func trashSelection() {
        guard !isInTrash else { return }
        perform(FileOps.trash(selectionURLs)); tab.selection = []
    }

    /// ⌘⌫:在搜尋框等文字輸入中是「刪除整行」,不能誤把檔案丟掉
    func trashFromMenu() {
        if NSApp.keyWindow?.firstResponder is NSText { return }
        guard mode == .browse, query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        trashSelection()
    }

    func duplicateSelection() { perform(FileOps.duplicate(selectionURLs)) }

    func newFolder() {
        let before = Set(tab.items.map(\.url))
        perform(FileOps.newFolder(in: currentFolder))
        Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if let created = tab.items.first(where: { !before.contains($0.url) }) {
                tab.selection = [created.url]
                renameTarget = created.url
            }
        }
    }

    func rename(_ url: URL, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("/"), clean != url.lastPathComponent else { return }
        perform(FileOps.rename(url, to: clean))
        let renamed = url.deletingLastPathComponent().appendingPathComponent(clean)
        if FileManager.default.fileExists(atPath: renamed.path) { tab.selection = [renamed] }
    }

    func copyToPasteboard(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    func paste(into dir: URL? = nil) {
        let urls = (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        perform(FileOps.copy(urls, into: dir ?? currentFolder))
    }

    /// 放到表格上:放下位置在資料夾列上就放進該資料夾,否則放進目前資料夾
    func dropOnTable(_ urls: [URL], at location: CGPoint) {
        guard !urls.isEmpty else { return }
        drop(urls, into: folderInTable(atDropLocation: location) ?? currentFolder)
    }

    /// 拖放位置底下的資料夾列(不在資料夾列上 → nil)
    func folderInTable(atDropLocation location: CGPoint) -> URL? {
        let items = tab.sortedItems
        guard let row = fileTableRow(atDropLocation: location), items.indices.contains(row), items[row].isBrowsable else { return nil }
        return items[row].url
    }

    // MARK: 彈簧資料夾

    /// 拖著東西停在資料夾上這麼久就打開它,可以一路往下層放
    static let springDelay: TimeInterval = 0.7

    /// 拖曳中游標停在哪個資料夾上(nil = 不在資料夾上)。換目標就重新計時。
    func springHover(_ target: URL?) {
        let target = target?.standardizedFileURL
        guard target != springTarget else { return }
        springTimer?.invalidate()
        springTimer = nil
        springTarget = target
        guard let target, target != currentFolder.standardizedFileURL,
              target != trashURL.standardizedFileURL, isBrowsableFolder(target) else { return }
        // 拖曳期間主執行緒跑在 event tracking 模式,計時器要掛在 common 模式才會觸發
        let t = Timer(timeInterval: Self.springDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.springTarget == target else { return }
                self.springTarget = nil
                self.springTimer = nil
                self.open(target)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        springTimer = t
    }

    /// 離開某個資料夾(只在它還是目前目標時才取消,避免把剛進入的下一個目標清掉)
    func springLeave(_ target: URL) {
        if springTarget == target.standardizedFileURL { springHover(nil) }
    }

    /// DropInfo.location 是以 SwiftUI 表格左上角為原點;換算成 NSTableView 的座標再查是哪一列
    private func fileTableRow(atDropLocation p: CGPoint) -> Int? {
        guard let window = FileTidyIntegration.visibleWindow,
              let table = Self.findFileTable(in: window.contentView!), let scroll = table.enclosingScrollView else { return nil }
        let inScroll = NSPoint(x: p.x, y: scroll.isFlipped ? p.y : scroll.bounds.height - p.y)
        let row = table.row(at: table.convert(inScroll, from: scroll))
        return row >= 0 ? row : nil
    }

    /// 拖放:同磁碟預設移動、跨磁碟或按住 ⌥ 為拷貝(與 Finder 一致)
    func drop(_ urls: [URL], into dir: URL) {
        let optionHeld = NSEvent.modifierFlags.contains(.option)
        let crossVolume = urls.contains { volume($0) != volume(dir) }
        let plan = optionHeld || crossVolume ? FileOps.copy(urls, into: dir) : FileOps.move(urls, into: dir)
        perform(plan)
    }

    private func volume(_ url: URL) -> String? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier.map { "\($0)" }
    }

    func undo() {
        guard let (entry, failures) = Executor.undoLatest(journal: journal) else { status = String(localized: "沒有可復原的操作"); return }
        history = journal.entries
        status = failures.isEmpty ? String(localized: "已復原「\(entry.title)」") : String(localized: "復原時有問題:") + failures.prefix(2).joined(separator: String(localized: "、"))
        generation += 1
        tab.reload()
    }

    func undo(_ entry: JournalEntry) {
        let failures = Executor.undo(entry, journal: journal)
        history = journal.entries
        status = failures.isEmpty ? String(localized: "已復原「\(entry.title)」") : String(localized: "復原時有問題:") + failures.prefix(2).joined(separator: String(localized: "、"))
        generation += 1
        tab.reload()
    }

    func copyPath(_ urls: [URL]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    // MARK: 整理工具(預覽 → 確認)

    func scanCurrent(recursive: Bool) async -> [FileEntry] {
        let dir = currentFolder
        busy = true
        defer { busy = false }
        return await Task.detached(priority: .userInitiated) { FileScanner.scan(dir, recursive: recursive) }.value
    }

    func setPlan(_ p: OperationPlan) {
        plan = p
        selected = Set(p.actions.map(\.id))
        status = p.actions.isEmpty ? String(localized: "沒有需要處理的項目") : String(localized: "預覽:\(p.title),共 \(p.actions.count) 項(尚未執行)")
    }

    func clearPlan() { plan = nil; selected = [] }

    func applyPlan() {
        guard let plan else { return }
        guard let resolutions = resolveConflicts(plan, selected: selected) else {
            status = String(localized: "已停止,沒有變更任何檔案")
            return
        }
        let r = Executor.apply(plan, selected: selected, resolutions: resolutions, journal: journal)
        history = journal.entries
        var msg = String(localized: "已完成 \(r.applied) 項,可用 ⌘Z 或「操作紀錄」還原")
        if !r.failures.isEmpty { msg += String(localized: ";\(r.failures.count) 項失敗:") + r.failures.prefix(2).joined(separator: String(localized: "、")) }
        status = msg
        clearPlan()
        generation += 1
        tab.reload()
    }

    /// 其他 App 要求「顯示/開啟」某個項目時(例如「在 Finder 中顯示」被轉過來):
    /// 資料夾 → 進入;檔案 → 到所在資料夾並選取。
    func handleExternalOpen(_ urls: [URL]) {
        guard let url = urls.first else { return }
        let pkg = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return }
        if isDir.boolValue, !pkg { open(url) } else { open(url.deletingLastPathComponent(), select: url) }
        FileTidyIntegration.showWindow()
    }

    // MARK: 系統整合

    func refreshIntegration() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        viewerIsDefault = FileViewerIntegration.isEnabled
    }

    /// 登入時自動開啟(系統登入項目)。第一次可能需要到「系統設定 › 一般 › 登入項目」核准。
    func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        var failed = false
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            failed = true
            status = String(localized: "設定登入項目失敗:\(error.localizedDescription)")
        }
        if service.status == .requiresApproval {
            status = String(localized: "需要在「系統設定 › 一般 › 登入項目」允許 LiriOS")
            SMAppService.openSystemSettingsLoginItems()
        } else if !failed {
            status = service.status == .enabled ? String(localized: "之後登入時會自動開啟 LiriOS") : String(localized: "已取消登入時自動開啟")
        }
        refreshIntegration()
    }

    func enableViewerDefault() { FileViewerIntegration.enableWithConfirmation(); refreshIntegration() }
    func disableViewerDefault() { FileViewerIntegration.disable(); refreshIntegration() }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func relative(_ url: URL) -> String {
        let p = url.standardizedFileURL.path
        let base = currentFolder.standardizedFileURL.path + "/"
        if p.hasPrefix(base) { return String(p.dropFirst(base.count)) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}
