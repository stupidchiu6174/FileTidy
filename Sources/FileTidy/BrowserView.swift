import SwiftUI
import AppKit
import QuickLook
import UniformTypeIdentifiers
import FileTidyCore

struct BrowserView: View {
    @Environment(AppModel.self) private var model
    @State private var renameText = ""

    var body: some View {
        @Bindable var model = model
        let tab = model.tab
        @Bindable var bTab = tab

        Group {
            if let error = tab.error {
                ContentUnavailableView("無法開啟", systemImage: "lock", description: Text(error))
            } else if model.viewMode == .columns {
                ColumnBrowserView()
            } else if model.viewMode == .gallery {
                GalleryView()
            } else if model.viewMode == .icons {
                IconGridView(
                    entries: tab.sortedItems.map { GridEntry(url: $0.url, name: $0.name, isFolder: $0.isBrowsable, isPackage: $0.isPackage) },
                    selection: $bTab.selection,
                    size: model.iconSize,
                    dropTarget: tab.url,
                    onTrash: { urls in model.tab.selection = Set(urls); model.trashSelection() },
                    menu: { sel in BrowseContextMenu(sel: sel) })
            } else {
                Table(of: DirItem.self, selection: $bTab.selection, sortOrder: $bTab.sortOrder) {
                    TableColumn("名稱", value: \.name) { item in
                        HStack(spacing: 6) {
                            FileIconView(url: item.url, isFolder: item.isBrowsable, isPackage: item.isPackage)
                            Text(item.name).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay {
                            FileDragOverlay(
                                url: item.url,
                                selectedURLs: { Array(model.tab.selection) },
                                onMouseDown: { mods in browseSelect(item.url, mods) },
                                onPlainClick: { if model.tab.selection.count > 1 { model.tab.selection = [item.url]; model.tab.anchor = item.url } },
                                onContextClick: { if !model.tab.selection.contains(item.url) { model.tab.selection = [item.url] } },
                                onActivate: { model.activate(item.url) })
                        }

                    }
                    TableColumn("修改日期", value: \.sortModified) { item in
                        Text(item.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—").foregroundStyle(.secondary)
                    }.width(min: 110, ideal: 150)
                    TableColumn("建立日期", value: \.sortCreated) { item in
                        Text(item.created.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—").foregroundStyle(.secondary)
                    }.width(min: 110, ideal: 150)
                    TableColumn("大小", value: \.sortSize) { item in
                        Text(item.size.map(formatBytes) ?? "—").foregroundStyle(.secondary).monospacedDigit()
                    }.width(min: 60, ideal: 80)
                    TableColumn("種類", value: \.kind) { item in
                        Text(item.kind).foregroundStyle(.secondary).lineLimit(1)
                    }.width(min: 80, ideal: 140)
                } rows: {
                    ForEach(tab.sortedItems) { item in
                        TableRow(item)
                    }
                }
                .contextMenu(forSelectionType: URL.self) { sel in
                    BrowseContextMenu(sel: sel)
                } primaryAction: { sel in
                    sel.forEach { model.activate($0) }
                }
                .onDrop(of: [.fileURL], delegate: FileDropDelegate(model: model))
                .onCopyCommand {
                    model.copyToPasteboard(model.selectionURLs)
                    return model.selectionURLs.map { NSItemProvider(object: $0 as NSURL) }
                }
                .onPasteCommand(of: [.fileURL]) { _ in model.paste() }
                .onDeleteCommand { model.trashSelection() }
                .onKeyPress(.space) {
                    model.quickLookURL = model.selectionURLs.first
                    return model.selectionURLs.isEmpty ? .ignored : .handled
                }
                .onKeyPress(.return) {
                    guard let u = model.selectionURLs.first else { return .ignored }
                    model.renameTarget = u
                    return .handled
                }
                .overlay { if tab.items.isEmpty { Text("空的資料夾").foregroundStyle(.secondary) } }
            }
        }
        .sheet(item: $model.renameTarget) { url in
            RenameSheet(url: url)
        }
    }

    private func browseSelect(_ url: URL, _ mods: NSEvent.ModifierFlags) {
        let tab = model.tab
        let r = SelectionLogic.click(url, command: mods.contains(.command), shift: mods.contains(.shift),
                                     order: tab.sortedItems.map(\.url),
                                     state: .init(selection: tab.selection, anchor: tab.anchor))
        tab.selection = r.selection
        tab.anchor = r.anchor
        // 按在已選取的項目上:先保留多選,放開時若沒有拖曳才收斂(見 onPlainClick)
    }
}

/// 檔案與資料夾的右鍵選單(列表與圖示檢視共用)
struct BrowseContextMenu: View {
    @Environment(AppModel.self) private var model
    let sel: Set<URL>

    var body: some View {
        let urls = Array(sel)
        if model.isInTrash {
            if urls.isEmpty {
                Button("清空垃圾桶…", role: .destructive) { model.confirmEmptyTrash = true }
            } else {
                Button("放回原處") { model.putBack(urls) }
                Button("快速查看") { model.quickLookURL = urls[0] }
                Button("拷貝路徑") { model.copyPath(urls) }
                Divider()
                Button("永久刪除…", role: .destructive) { model.pendingDelete = urls }
            }
        } else if urls.isEmpty {
            Button("新增資料夾") { model.newFolder() }
            Button("貼上") { model.paste() }
        } else {
            Button("開啟") { urls.forEach { model.activate($0) } }
            if urls.count == 1 {
                Button("在新分頁開啟") { model.newTab(urls[0]) }
                Button("快速查看") { model.quickLookURL = urls[0] }
                Button("重新命名") { model.renameTarget = urls[0] }
            }
            Divider()
            Button("拷貝") { model.copyToPasteboard(urls) }
            Button("貼上") { model.paste(into: urls.count == 1 && urls[0].hasDirectoryPath ? urls[0] : nil) }
            Button("製作副本") { model.tab.selection = sel; model.duplicateSelection() }
            Button("拷貝路徑") { model.copyPath(urls) }
            if urls.count == 1, isBrowsableFolder(urls[0]) {
                Divider()
                Button("加到側邊欄") { model.addSidebarFolders([urls[0]]) }
                AnalysisMenuItems(folder: urls[0])
            }
            Divider()
            Button("移到垃圾桶", role: .destructive) { model.tab.selection = sel; model.trashSelection() }
        }
    }
}

/// 「分析資料夾內容」的右鍵選單項目。已經分析過的資料夾會顯示「查看分析結果」和分析的時間,
/// 沒分析過的則顯示「分析資料夾內容…」,讓使用者一眼知道有沒有結果。
struct AnalysisMenuItems: View {
    @Environment(AppModel.self) private var model
    let folder: URL

    var body: some View {
        if let existing = AnalysisStore.shared.load(folder.path) {
            Button("查看分析結果(\(Self.relative(existing.analyzedAt)))") { model.analysisTarget = AnalysisRequest(url: folder) }
            Button("重新分析資料夾內容") { model.analysisTarget = AnalysisRequest(url: folder, rerun: true) }
        } else {
            Button("分析資料夾內容…") { model.analysisTarget = AnalysisRequest(url: folder) }
        }
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// 直接處理 NSItemProvider 的放下目標(SwiftUI 的 Transferable 版本在 Table 上解不出內容)。
/// 放在哪個資料夾,由游標所在的表格列決定;不在資料夾列上就放進目前資料夾。
struct FileDropDelegate: DropDelegate {
    let model: AppModel

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: NSEvent.modifierFlags.contains(.option) ? .copy : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        let location = info.location  // 放下的位置(表格左上為原點),用來判斷放在哪一列
        guard !providers.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for p in providers { if let u = await loadFileURL(p) { urls.append(u) } }
            if urls.isEmpty {
                // 備援:直接讀 AppKit 的拖曳剪貼簿
                let pb = NSPasteboard(name: .drag)
                urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            }
            model.dropOnTable(urls, at: location)
        }
        return true
    }
}

/// 側邊欄項目的放下目標:放到「桌面」「App」「垃圾桶」等位置。
/// 垃圾桶 = 移到垃圾桶(可 ⌘Z);其他資料夾 = 同磁碟移動、跨磁碟或按住 ⌥ 拷貝。
struct FolderDropDelegate: DropDelegate {
    let model: AppModel
    let target: URL
    @Binding var hovered: URL?

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }
    func dropEntered(info: DropInfo) { hovered = target }
    func dropExited(info: DropInfo) { if hovered == target { hovered = nil } }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if target.standardizedFileURL == model.trashURL.standardizedFileURL { return DropProposal(operation: .move) }
        return DropProposal(operation: NSEvent.modifierFlags.contains(.option) ? .copy : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        hovered = nil
        Task { @MainActor in
            var urls: [URL] = []
            for p in providers { if let u = await loadFileURL(p) { urls.append(u) } }
            guard !urls.isEmpty else { return }
            if target.standardizedFileURL == model.trashURL.standardizedFileURL {
                model.perform(FileOps.trash(urls))
            } else {
                model.drop(urls, into: target)
            }
        }
        return true
    }
}

func loadFileURL(_ provider: NSItemProvider) async -> URL? {
    // 檔案 URL 要用 NSItemProviderReading 讀取;用 loadItem 讀原始資料會得到空內容
    if provider.canLoadObject(ofClass: URL.self) {
        let url: URL? = await withCheckedContinuation { cont in
            _ = provider.loadObject(ofClass: URL.self) { obj, _ in cont.resume(returning: obj) }
        }
        if let url, url.isFileURL { return url }
    }
    return await withCheckedContinuation { cont in
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            if let u = item as? URL { cont.resume(returning: u) }
            else if let d = item as? Data, !d.isEmpty, let u = URL(dataRepresentation: d, relativeTo: nil) { cont.resume(returning: u) }
            else { cont.resume(returning: nil) }
        }
    }
}

extension URL: @retroactive Identifiable { public var id: String { path } }

struct RenameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let url: URL
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("重新命名").font(.headline)
            TextField("名稱", text: $text)
                .frame(width: 360)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("好") { commit() }.keyboardShortcut(.defaultAction).buttonStyle(.glassProminent)
            }
        }
        .padding(20)
        .onAppear { text = url.lastPathComponent }
    }

    private func commit() {
        model.rename(url, to: text)
        dismiss()
    }
}

// MARK: - 搜尋結果

struct SearchResultsView: View {
    @Environment(AppModel.self) private var model
    private func searchSelect(_ path: String, _ mods: NSEvent.ModifierFlags) {
        let r = SelectionLogic.click(URL(fileURLWithPath: path), command: mods.contains(.command), shift: mods.contains(.shift),
                                     order: model.hits.map { URL(fileURLWithPath: $0.item.path) },
                                     state: .init(selection: Set(model.searchSelection.map { URL(fileURLWithPath: $0) }),
                                                  anchor: model.searchAnchor.map { URL(fileURLWithPath: $0) }))
        model.searchSelection = Set(r.selection.map(\.path))
        model.searchAnchor = r.anchor?.path
    }

    var body: some View {
        @Bindable var model = model
        if model.hits.isEmpty {
            if model.searching {
                VStack(spacing: 8) { ProgressView(); Text("搜尋中…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(model.phase.isCrawling ? String(localized: "索引建立中…") : String(localized: "找不到符合的項目"), systemImage: "magnifyingglass",
                                       description: Text(model.phaseText))
            }
        } else if model.viewMode == .icons {
            IconGridView(
                entries: model.hits.map {
                    GridEntry(url: $0.item.url, name: $0.item.name, isFolder: $0.item.isDirectory, isPackage: $0.item.path.hasSuffix(".app"))
                },
                selection: Binding(
                    get: { Set(model.searchSelection.map { URL(fileURLWithPath: $0) }) },
                    set: { model.searchSelection = Set($0.map(\.path)) }),
                size: model.iconSize,
                dropTarget: nil,
                allowPaste: false,
                onTrash: { urls in model.perform(FileOps.trash(urls)); model.runSearch() },
                menu: { sel in SearchContextMenu(paths: Set(sel.map(\.path))) })
        } else {
            Table(of: SearchHit.self, selection: $model.searchSelection) {
                TableColumn("名稱") { h in
                    HStack(spacing: 6) {
                        FileIconView(url: h.item.url, isFolder: h.item.isDirectory, isPackage: h.item.path.hasSuffix(".app"))
                        Text(h.item.name).lineLimit(1)
                        if let s = h.semantic, s > h.lexical {
                            Text("語意").font(.caption2).padding(.horizontal, 4).background(.blue.opacity(0.15), in: .capsule)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay {
                        FileDragOverlay(
                            url: h.item.url,
                            selectedURLs: { model.searchSelection.map { URL(fileURLWithPath: $0) } },
                            onMouseDown: { mods in searchSelect(h.item.path, mods) },
                            onPlainClick: { if model.searchSelection.count > 1 { model.searchSelection = [h.item.path]; model.searchAnchor = h.item.path } },
                            onContextClick: { if !model.searchSelection.contains(h.item.path) { model.searchSelection = [h.item.path] } },
                            onActivate: { model.activate(h.item.url) })
                    }
                }
                TableColumn("位置") { h in
                    Text(model.relative(URL(fileURLWithPath: h.item.path).deletingLastPathComponent()))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        .help(h.item.path)
                }
                TableColumn("修改日期") { h in
                    Text(h.item.modified > 0 ? Date(timeIntervalSince1970: h.item.modified).formatted(date: .abbreviated, time: .shortened) : "—")
                        .foregroundStyle(.secondary)
                }.width(min: 100, ideal: 140)
                TableColumn("大小") { h in
                    Text(h.item.isDirectory ? "—" : formatBytes(h.item.size)).foregroundStyle(.secondary).monospacedDigit()
                }.width(min: 60, ideal: 80)
                TableColumn("符合度") { h in
                    Text(String(format: "%.0f%%", h.score * 100)).foregroundStyle(.secondary).monospacedDigit()
                }.width(60)
            } rows: {
                ForEach(model.hits) { h in TableRow(h) }
            }
            .contextMenu(forSelectionType: String.self) { sel in
                SearchContextMenu(paths: sel)
            } primaryAction: { sel in
                if let p = sel.first { model.activate(URL(fileURLWithPath: p)) }
            }
            .onKeyPress(.space) {
                model.quickLookURL = model.searchSelection.first.map { URL(fileURLWithPath: $0) }
                return .handled
            }
        }
    }
}

extension CatalogPhase {
    var isCrawling: Bool { if case .crawling = self { true } else { false } }
}


/// 搜尋結果的右鍵選單(列表與圖示檢視共用)
struct SearchContextMenu: View {
    @Environment(AppModel.self) private var model
    let paths: Set<String>

    var body: some View {
        if let path = paths.first {
            let url = URL(fileURLWithPath: path)
            let urls = paths.map { URL(fileURLWithPath: $0) }
            Button("開啟") { model.activate(url) }
            Button("顯示所在位置") { model.open(url.deletingLastPathComponent(), select: url) }
            Button("拷貝") { model.copyToPasteboard(urls) }
            Button("拷貝路徑") { model.copyPath(urls) }
            Divider()
            Button("移到垃圾桶", role: .destructive) { model.perform(FileOps.trash(urls)); model.runSearch() }
        }
    }
}
