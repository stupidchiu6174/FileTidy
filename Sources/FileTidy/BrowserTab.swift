import SwiftUI
import AppKit
import UniformTypeIdentifiers
import QuickLookThumbnailing
import FileTidyCore

extension DirItem {
    var sortModified: Date { modified ?? .distantPast }
    var sortSize: Int64 { size ?? -1 }
}

/// 監看單一資料夾內容變動(用於即時更新列表)
final class DirWatcher {
    private var source: DispatchSourceFileSystemObject?

    init(url: URL, onChange: @escaping () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        s.setEventHandler(handler: onChange)
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }
    deinit { source?.cancel() }
}

@MainActor @Observable
final class BrowserTab: Identifiable {
    let id = UUID()
    var url: URL
    var items: [DirItem] = []
    var selection = Set<URL>()
    /// Shift 點擊範圍選取的起點(上一次不按 Shift 點擊的項目)
    var anchor: URL?
    var sortOrder = [KeyPathComparator(\DirItem.name, comparator: .localizedStandard)]
    var showHidden = false { didSet { reload() } }
    var error: String?
    private(set) var back: [URL] = []
    private(set) var forward: [URL] = []
    @ObservationIgnored private var watcher: DirWatcher?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSelect: URL?

    var title: String {
        if url.path == "/" { return "Macintosh HD" }
        return url.standardizedFileURL.path == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path ? String(localized: "垃圾桶") : url.lastPathComponent
    }
    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }
    var canGoUp: Bool { url.path != "/" }

    /// 資料夾排在前面,其餘依目前排序
    var sortedItems: [DirItem] {
        let sorted = items.sorted(using: sortOrder)
        return sorted.filter(\.isBrowsable) + sorted.filter { !$0.isBrowsable }
    }

    init(url: URL) {
        self.url = url
        reload()
        watch()
    }

    func go(_ target: URL, select: URL? = nil, record: Bool = true) {
        let target = target.standardizedFileURL
        if record, target != url { back.append(url); forward.removeAll() }
        url = target
        selection = select.map { [$0] } ?? []
        pendingSelect = select
        reload()
        watch()
    }

    func goBack() { guard let prev = back.popLast() else { return }; forward.append(url); go(prev, record: false) }
    func goForward() { guard let next = forward.popLast() else { return }; back.append(url); go(next, record: false) }
    func goUp() { if canGoUp { go(url.deletingLastPathComponent()) } }

    func reload() {
        reloadTask?.cancel()
        let target = url, hidden = showHidden
        reloadTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)  // 合併連續事件
            guard !Task.isCancelled else { return }
            let result = await Task.detached { Result { try DirectoryLister.list(target, showHidden: hidden) } }.value
            guard !Task.isCancelled, target == url else { return }
            switch result {
            case .success(let list):
                items = list; error = nil
                selection = selection.filter { s in list.contains { $0.url == s } }
                if let p = pendingSelect { selection = [p]; pendingSelect = nil }
            case .failure(let e):
                items = []
                let ns = e as NSError
                error = ns.code == NSFileReadNoPermissionError || ns.code == 257
                    ? String(localized: "沒有權限讀取這個資料夾。請到「系統設定 → 隱私權與安全性 → 完全磁碟取用權限」開啟 LiriOS。")
                    : e.localizedDescription
            }
        }
    }

    private func watch() {
        watcher = DirWatcher(url: url) { [weak self] in self?.reload() }
    }
}

@MainActor
enum Icons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for item: DirItem) -> NSImage {
        icon(url: item.url, isFolder: item.isBrowsable, isPackage: item.isPackage)
    }

    static func icon(url: URL, isFolder: Bool, isPackage: Bool) -> NSImage {
        let key: String
        if isFolder { key = "folder" }
        else if isPackage || url.pathExtension.isEmpty { key = url.path }
        else { key = "." + url.pathExtension.lowercased() }
        if let hit = cache[key] { return hit }
        let img: NSImage
        if isFolder { img = NSWorkspace.shared.icon(for: .folder) }
        else if isPackage || url.pathExtension.isEmpty { img = NSWorkspace.shared.icon(forFile: url.path) }
        else { img = NSWorkspace.shared.icon(for: UTType(filenameExtension: url.pathExtension) ?? .data) }
        cache[key] = img
        return img
    }

    static func icon(path: String) -> NSImage { NSWorkspace.shared.icon(forFile: path) }
}

/// 真實縮圖(圖片/PDF/影片/文件等);產生前先顯示通用圖示,取不到縮圖時維持通用圖示。
@MainActor
enum Thumbs {
    private static var cache: [String: NSImage] = [:]
    private static var largest: [URL: NSImage] = [:]
    private static func key(_ url: URL, _ points: CGFloat) -> String { "\(url.path)@\(Int(points))" }

    /// 任意尺寸中已有的最大那張(快速查看的過場影像用)
    static func cached(_ url: URL) -> NSImage? { largest[url] }

    static func thumbnail(for url: URL, points: CGFloat) async -> NSImage? {
        if let hit = cache[key(url, points)] { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: points, height: points),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        if cache.count > 3000 { cache.removeAll(); largest.removeAll() }
        cache[key(url, points)] = rep.nsImage
        if (largest[url]?.size.width ?? 0) < points { largest[url] = rep.nsImage }
        return rep.nsImage
    }
}

struct FileIconView: View {
    let url: URL
    let isFolder: Bool
    let isPackage: Bool
    var points: CGFloat = 20
    @State private var thumb: NSImage?

    /// 縮圖的圓角:隨尺寸放大,但不超過一定比例,小圖不會被削得太圓
    private var radius: CGFloat { max(2.5, min(points * 0.085, 10)) }

    var body: some View {
        Group {
            if let thumb {
                // 真正的內容縮圖(圖片、PDF、文件…):圓角 + 極細邊框,大圖再加柔和陰影,和 Finder 的圖示檢視一致
                Image(nsImage: thumb)
                    .resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
                    .shadow(color: .black.opacity(points >= 44 ? 0.28 : 0), radius: points >= 44 ? 2.5 : 0, y: 1)
            } else {
                // 通用圖示(資料夾、App、副檔名圖示)本身就有形狀與透明背景,不另外裁切
                Image(nsImage: Icons.icon(url: url, isFolder: isFolder, isPackage: isPackage))
                    .resizable().scaledToFit()
            }
        }
        .frame(width: points, height: points)
        .task(id: url) {
            guard !isFolder, !isPackage else { return }
            thumb = await Thumbs.thumbnail(for: url, points: points)
        }
    }
}
