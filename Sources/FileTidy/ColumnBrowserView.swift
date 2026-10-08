import SwiftUI
import AppKit
import FileTidyCore

/// 「欄」顯示:每選一個資料夾就在右邊多開一欄;選到檔案時,最右邊顯示預覽。
/// 欄的內容完全由「目前資料夾 + 選取的項目」推導,不另外維護狀態,所以和路徑列、選單等一致。
struct ColumnBrowserView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @State private var cache: [URL: [DirItem]] = [:]
    @State private var version = 0

    private let columnWidth: CGFloat = 220

    var body: some View {
        let tab = model.tab
        let sel = tab.selection.count == 1 ? tab.selection.first : nil
        let chain = columns(root: tab.url, sel: sel)
        let showPreview = sel.map { !isBrowsableFolder($0) } ?? false

        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(chain, id: \.self) { dir in
                        column(dir, sel: sel, isLeaf: dir == chain.last && !showPreview)
                            .frame(width: columnWidth)
                        Divider()
                    }
                    if let sel, showPreview {
                        PreviewColumn(url: sel).frame(width: 280)
                    }
                    Color.clear.frame(width: 1, height: 1).id("end")
                }
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }
            .onChange(of: chain.count + (showPreview ? 1 : 0)) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("end", anchor: .trailing) }
            }
        }
        .task(id: "\(chain.map(\.path))|\(version)|\(model.tab.showHidden)") { await loadMissing(chain) }
        .onChange(of: tab.items) { _, _ in cache = [:]; version += 1 }
        .onChange(of: tab.url) { _, _ in cache = [:]; version += 1 }
        .contextMenu { BrowseContextMenu(sel: []) }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
            move(press.key, chain: chain, sel: sel); return .handled
        }
        .onKeyPress(.space) {
            guard let sel else { return .ignored }
            model.quickLookURL = sel; return .handled
        }
        .onKeyPress(.return) {
            guard let sel else { return .ignored }
            model.renameTarget = sel; return .handled
        }
        .onCopyCommand {
            model.copyToPasteboard(model.selectionURLs)
            return model.selectionURLs.map { NSItemProvider(object: $0 as NSURL) }
        }
        .onPasteCommand(of: [.fileURL]) { _ in model.paste(into: sel.flatMap { isBrowsableFolder($0) ? $0 : nil }) }
        .onDeleteCommand { model.trashSelection() }
    }

    // MARK: 欄的推導

    /// 從目前資料夾到選取項目的每一層資料夾;選取的是資料夾時,它自己也是一欄
    private func columns(root: URL, sel: URL?) -> [URL] {
        var dirs = [root]
        guard let sel, sel.path.hasPrefix(root.path + "/") else { return dirs }
        let comps = sel.path.dropFirst(root.path.count + 1).split(separator: "/").map(String.init)
        var cur = root
        for (i, c) in comps.enumerated() {
            cur = cur.appendingPathComponent(c)
            if i < comps.count - 1 { dirs.append(cur) }
            else if isBrowsableFolder(sel) { dirs.append(sel) }
        }
        return dirs
    }

    /// 這一欄裡,位於「選取路徑」上的那個子項目(顯示成已選取)
    private func onPath(in dir: URL, sel: URL?) -> String? {
        guard let sel, sel.path.hasPrefix(dir.path + "/") else { return nil }
        return String(sel.path.dropFirst(dir.path.count + 1).split(separator: "/").first ?? "")
    }

    private func loadMissing(_ chain: [URL]) async {
        let hidden = model.tab.showHidden
        for dir in chain where cache[dir] == nil {
            let list = await Task.detached { () -> [DirItem] in
                let items = (try? DirectoryLister.list(dir, showHidden: hidden)) ?? []
                let sorted = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                return sorted.filter(\.isBrowsable) + sorted.filter { !$0.isBrowsable }
            }.value
            cache[dir] = list
        }
    }

    // MARK: 一欄

    private func column(_ dir: URL, sel: URL?, isLeaf: Bool) -> some View {
        let items = cache[dir] ?? []
        let pathName = onPath(in: dir, sel: sel)
        let isActive = sel?.deletingLastPathComponent().path == dir.path  // 選取項目所在的那一欄
        return ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(items) { item in
                    row(item, highlighted: item.name == pathName, strong: isActive && item.name == pathName)
                }
            }
            .padding(6)
        }
        .overlay { if items.isEmpty && cache[dir] != nil { Text("空的資料夾").font(.caption).foregroundStyle(.secondary) } }
    }

    private func row(_ item: DirItem, highlighted: Bool, strong: Bool) -> some View {
        HStack(spacing: 6) {
            FileIconView(url: item.url, isFolder: item.isBrowsable, isPackage: item.isPackage, points: 18)
            Text(item.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if item.isBrowsable {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(strong ? Color.white : Color.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(strong ? Color.white : Color.primary)
        .background(strong ? Color.accentColor : (highlighted ? Color.secondary.opacity(0.28) : .clear),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .overlay {
            FileDragOverlay(
                url: item.url,
                selectedURLs: { [item.url] },
                onMouseDown: { _ in focused = true; model.tab.selection = [item.url] },
                onPlainClick: {},
                onContextClick: { model.tab.selection = [item.url] },
                onActivate: { model.activate(item.url) })
        }
        .contextMenu { BrowseContextMenu(sel: [item.url]) }
    }

    // MARK: 鍵盤

    /// ↑↓ 在同一欄移動;→ 進入選取的資料夾;← 回到上一層
    private func move(_ key: KeyEquivalent, chain: [URL], sel: URL?) {
        let tab = model.tab
        guard let sel else {
            if let first = cache[chain[0]]?.first { tab.selection = [first.url] }
            return
        }
        switch key {
        case .upArrow, .downArrow:
            let parent = sel.deletingLastPathComponent()
            guard let items = cache[parent], let i = items.firstIndex(where: { $0.url.path == sel.path }) else { return }
            let next = min(max(i + (key == .upArrow ? -1 : 1), 0), items.count - 1)
            tab.selection = [items[next].url]
        case .rightArrow:
            if isBrowsableFolder(sel), let first = cache[sel]?.first { tab.selection = [first.url] }
        case .leftArrow:
            let parent = sel.deletingLastPathComponent()
            if parent.path.hasPrefix(tab.url.path), parent.path != tab.url.path { tab.selection = [parent] }
        default: break
        }
    }
}

/// 選到檔案時,最右邊的預覽欄:大縮圖、名稱與資訊
private struct PreviewColumn: View {
    let url: URL

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                FileIconView(url: url, isFolder: false, isPackage: url.pathExtension == "app", points: 200)
                    .padding(.top, 16)
                Text(url.lastPathComponent).font(.headline).multilineTextAlignment(.center).textSelection(.enabled)
                Divider()
                FileInfoGrid(url: url)
            }
            .padding(14)
        }
    }
}
