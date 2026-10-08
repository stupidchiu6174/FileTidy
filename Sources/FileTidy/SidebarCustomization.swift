import SwiftUI
import AppKit
import FileTidyCore

/// 側邊欄設定的保存
enum SidebarStore {
    private static let key = "sidebarLayout"

    static func load() -> SidebarLayout {
        guard let data = UserDefaults.standard.data(forKey: key),
              var layout = try? JSONDecoder().decode(SidebarLayout.self, from: data) else { return .defaults }
        layout.normalize()
        return layout
    }

    static func save(_ layout: SidebarLayout) {
        if let data = try? JSONEncoder().encode(layout) { UserDefaults.standard.set(data, forKey: key) }
    }
}

struct SidebarEditRequest: Identifiable { let id: UUID }

extension AppModel {
    /// 預設位置的代號 → 名稱、圖示、實際位置
    static func builtinPlace(_ id: String, trash: URL) -> (name: String, icon: String, url: URL)? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch id {
        case "home": return (String(localized: "個人"), "house", home)
        case "desktop": return (String(localized: "桌面"), "menubar.dock.rectangle", home.appendingPathComponent("Desktop"))
        case "documents": return (String(localized: "文件"), "doc", home.appendingPathComponent("Documents"))
        case "downloads": return (String(localized: "下載項目"), "arrow.down.circle", home.appendingPathComponent("Downloads"))
        case "pictures": return (String(localized: "圖片"), "photo", home.appendingPathComponent("Pictures"))
        case "movies": return (String(localized: "影片"), "film", home.appendingPathComponent("Movies"))
        case "music": return (String(localized: "音樂"), "music.note", home.appendingPathComponent("Music"))
        case "applications": return (String(localized: "App"), "square.grid.2x2", URL(fileURLWithPath: "/Applications"))
        case "trash": return (String(localized: "垃圾桶"), "trash", trash)
        default: return nil
        }
    }

    /// 預設位置代號 → 路徑,加入資料夾時用來避免重複加入桌面、下載這類預設項目
    var builtinPaths: [String: String] {
        Dictionary(uniqueKeysWithValues: SidebarLayout.builtinIDs.compactMap { id in
            Self.builtinPlace(id, trash: trashURL).map { (id, $0.url.path) }
        })
    }

    // MARK: 編輯動作

    func addSidebarFolders(_ urls: [URL]) {
        var added = 0, existing = 0
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            switch sidebar.addFolder(url.path, builtinPaths: builtinPaths) {
            case .added, .revealedBuiltin: added += 1
            case .alreadyThere: existing += 1
            }
        }
        if added > 0 { status = String(localized: "已加到側邊欄:\(added) 個資料夾") }
        else if existing > 0 { status = String(localized: "這個資料夾已經在側邊欄上了") }
    }

    func addSidebarFolderViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "加入")
        panel.message = String(localized: "選擇要加到側邊欄的資料夾")
        if panel.runModal() == .OK { addSidebarFolders(panel.urls) }
    }

    /// 檔案選單「加到側邊欄」:選了資料夾就加它;沒選東西就加目前所在的資料夾
    func addSelectionToSidebar() {
        let sel = effectiveSelection.filter { isBrowsableFolder($0) }
        addSidebarFolders(sel.isEmpty ? [currentFolder] : sel)
    }

    func moveSidebar(from source: IndexSet, to destination: Int) {
        sidebar.moveShown(places.compactMap(\.entryID), from: source, to: destination)
    }
}

// MARK: - 放到「加入資料夾」那一列:把拖來的資料夾加進側邊欄

struct SidebarAddDropDelegate: DropDelegate {
    let model: AppModel
    @Binding var hovered: Bool

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }
    func dropEntered(info: DropInfo) { hovered = true }
    func dropExited(info: DropInfo) { hovered = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        hovered = false
        guard !providers.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for p in providers { if let u = await loadFileURL(p) { urls.append(u) } }
            model.addSidebarFolders(urls)
        }
        return true
    }
}

// MARK: - 編輯單一項目的名稱與圖示

struct SidebarEntryEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entryID: UUID
    @State private var title = ""
    @State private var symbol = ""

    private static let symbols = [
        "folder", "folder.fill", "star", "heart", "bookmark", "tray.full", "archivebox", "externaldrive",
        "briefcase", "graduationcap", "book", "doc.text", "photo", "camera", "film", "music.note",
        "gamecontroller", "hammer", "paintbrush", "terminal", "globe", "cloud", "house", "flag",
    ]

    private var entry: SidebarEntry? { model.sidebar.entries.first { $0.id == entryID } }
    private var defaults: (name: String, icon: String) {
        if let b = entry?.builtin, let d = AppModel.builtinPlace(b, trash: model.trashURL) { return (d.name, d.icon) }
        return (entry?.path.map { ($0 as NSString).lastPathComponent } ?? "", "folder")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("編輯側邊欄項目").font(.headline)
            HStack(spacing: 10) {
                Image(systemName: symbol.isEmpty ? defaults.icon : symbol).font(.title2).frame(width: 34)
                TextField(defaults.name, text: $title).textFieldStyle(.roundedBorder)
            }
            Text("只會改側邊欄上顯示的名稱與圖示,不會改磁碟上的資料夾。").font(.caption).foregroundStyle(.secondary)

            Text("圖示").font(.subheadline.bold())
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 6), count: 8), spacing: 6) {
                ForEach(Self.symbols, id: \.self) { s in
                    Button { symbol = s } label: {
                        Image(systemName: s).frame(width: 34, height: 30)
                            .background(symbol == s ? Color.accentColor.opacity(0.28) : Color.secondary.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Button("還原名稱與圖示") { title = ""; symbol = "" }.disabled(title.isEmpty && symbol.isEmpty)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("好") {
                    model.sidebar.customize(entryID, title: title, symbol: symbol)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { title = entry?.title ?? ""; symbol = entry?.symbol ?? "" }
    }
}

// MARK: - 自訂側邊欄(整份清單)

struct SidebarCustomizeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Text("自訂側邊欄").font(.title3.bold())
            Text("勾選要顯示的項目,拖曳可以調整順序。你加進來的資料夾可以按右邊的 ✕ 移除。").font(.callout).foregroundStyle(.secondary)

            List {
                ForEach(model.sidebar.entries) { entry in row(entry) }
                    .onMove { model.sidebar.move(from: $0, to: $1) }
            }
            .frame(minHeight: 260)
            .listStyle(.bordered)

            Toggle("顯示磁碟", isOn: $model.sidebar.showVolumes)
            Toggle("顯示整理工具", isOn: $model.sidebar.showTools)

            HStack {
                Button("加入資料夾…") { model.addSidebarFolderViaPanel() }
                Button("還原預設側邊欄", role: .destructive) { model.sidebar.restoreDefaults() }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.glassProminent)
            }
        }
        .padding(20)
        .frame(width: 480, height: 520)
    }

    @ViewBuilder private func row(_ entry: SidebarEntry) -> some View {
        let info = describe(entry)
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { !entry.hidden }, set: { model.sidebar.setHidden(entry.id, !$0) })).labelsHidden()
            Image(systemName: info.icon).frame(width: 22).foregroundStyle(info.missing ? Color.orange : .secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(info.name).lineLimit(1)
                if let sub = info.subtitle { Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
            }
            Spacer()
            if info.missing { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help("找不到這個資料夾") }
            Button { model.sidebarEditTarget = SidebarEditRequest(id: entry.id) } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless).help("編輯名稱與圖示…")
            if entry.isCustomFolder {
                Button { model.sidebar.remove(entry.id) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("從側邊欄移除")
            }
        }
        .opacity(entry.hidden ? 0.5 : 1)
    }

    private func describe(_ e: SidebarEntry) -> (name: String, icon: String, subtitle: String?, missing: Bool) {
        if let b = e.builtin, let d = AppModel.builtinPlace(b, trash: model.trashURL) {
            return (e.title ?? d.name, e.symbol ?? d.icon, nil, !FileManager.default.fileExists(atPath: d.url.path))
        }
        let path = e.path ?? ""
        return (e.title ?? (path as NSString).lastPathComponent, e.symbol ?? "folder", path,
                !FileManager.default.fileExists(atPath: path))
    }
}
