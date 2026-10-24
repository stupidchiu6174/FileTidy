import SwiftUI
import FileTidyCore

/// LiriOS 主程式與檔案管理模組之間的介面。模組內其他型別都是 internal。
@MainActor
public enum FileTidyIntegration {
    public static let windowID = "files"
    static let hideAtLoginKey = "hideWindowAtLogin"

    /// 視窗關著時重新開啟它(SwiftUI 的 openWindow,由 WindowAttacher 在視窗建立時取得)
    static var openWindow: () -> Void = {}

    /// 檔案管理視窗(由 ContentView 掛上;LiriOS 還有壁紙、小工具、監測等其他視窗,
    /// 不能再用「第一個非面板視窗」來找)
    static weak var window: NSWindow?
    static var visibleWindow: NSWindow? {
        guard let w = window, w.isVisible, w.contentView != nil else { return nil }
        return w
    }
    /// 登入時不顯示視窗:SwiftUI 建好視窗後直接關掉
    static var closeWindowOnAttach = false

    /// 把檔案管理視窗叫到前面(關著就重新開啟)
    public static func showWindow() {
        let present = {
            // macOS 14 起的協作式啟用:由使用者點擊觸發的請求(例如別的 App 的「在 Finder 中顯示」)
            // 系統會讓出前景;ignoringOtherApps 已經沒有作用
            NSApp.activate()
            if let w = window, w.contentView != nil {
                if w.isMiniaturized { w.deminiaturize(nil) }
                w.makeKeyAndOrderFront(nil)
                // 系統偶爾不讓背景 App 搶到前景(例如別的 App 正在用);至少讓視窗本身浮上來
                w.orderFrontRegardless()
            } else {
                openWindow()
            }
        }
        // LiriOS 平常是沒有 Dock 圖示的背景 App。剛切成一般 App 的那一拍就要求啟用會被系統忽略——
        // 「在 Finder 中顯示」明明送到了、視窗卻沒跑出來,就是這個原因。等下一拍再啟用。
        if NSApp.activationPolicy() != .regular {
            // 視窗還在(關閉只是藏起來)就先讓它浮上來:切換成一般 App、等系統啟用要好幾百毫秒,
            // 不必等那個才看得到視窗
            if let w = window, w.contentView != nil { w.orderFrontRegardless() }
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.async(execute: present)
        } else {
            present()
        }
    }

    /// 是否由「登入項目」啟動:啟動事件(oapp)帶有 'lgit' 旗標
    static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == 0x6F617070,  // 'oapp'
              let flag = event.paramDescriptor(forKeyword: 0x70726474)  // 'prdt'
        else { return false }
        return flag.enumCodeValue == 0x6C676974  // 'lgit'
    }

    /// 在 applicationDidFinishLaunching 呼叫
    public static func didFinishLaunching() {
        // 原本把舊的 FileTidy 設成預設檔案檢視器的話,改指向 LiriOS——
        // 否則「在 Finder 中顯示」會去叫醒舊 App(甚至是垃圾桶裡那一份)
        FileViewerIntegration.takeOverFromLegacyApp()

        // 若設定了「啟動時隱藏 Finder」:稍等一下(讓視窗先出現)再隱藏
        if FinderControl.hideOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { FinderControl.hide() }
        }
        // --hidden 是給手動測試用的;正常使用只看「登入時不顯示視窗」選項
        let wantsHidden = CommandLine.arguments.contains("--hidden")
            || (UserDefaults.standard.bool(forKey: hideAtLoginKey) && launchedAsLoginItem)
        guard wantsHidden else { return }
        // 只關檔案管理視窗;不能 NSApp.hide,那會連側面板、壁紙、桌面小工具一起藏起來
        if let w = window { hide(w) } else { closeWindowOnAttach = true }
    }

    /// 「關閉」檔案管理視窗其實只是藏起來。SwiftUI 真的關掉視窗時會拆掉整個畫面,
    /// 下次「在 Finder 中顯示」或開資料夾就得從頭重建視窗,要等好一下才出現。
    static func hide(_ w: NSWindow) {
        w.orderOut(nil)
        // 原本由視窗關閉通知觸發的「沒有一般視窗就收回 Dock 圖示」,藏起來時自己做
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let stillOpen = NSApp.windows.contains { $0 !== w && $0.isVisible && $0.canBecomeMain }
            if !stillOpen, !w.isVisible { NSApp.setActivationPolicy(.accessory) }
        }
    }

    /// 包住 SwiftUI 原本的視窗代理:按關閉(紅色按鈕、⌘W)時改成 hide,其他訊息照轉
    final class HideOnCloseDelegate: NSObject, NSWindowDelegate {
        weak var original: NSWindowDelegate?
        init(original: NSWindowDelegate?) { self.original = original }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if original?.windowShouldClose?(sender) == false { return false }
            MainActor.assumeIsolated { FileTidyIntegration.hide(sender) }
            return false
        }
        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
        }
        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            original?.responds(to: aSelector) == true ? original : nil
        }
    }
    /// window.delegate 是 weak,要自己留住
    static var closeDelegate: HideOnCloseDelegate?

    /// 其他 App 用 LiriOS 開啟資料夾/檔案(預設檔案檢視器)
    public static func open(_ urls: [URL]) {
        AppModel.shared.handleExternalOpen(urls)
    }
}

/// 檔案管理視窗(原 FileTidy 主視窗)與它的選單
public struct FileTidyWindow: Scene {
    @State private var model = AppModel.shared

    public init() {}

    public var body: some Scene {
        Window("檔案", id: FileTidyIntegration.windowID) {
            ContentView()
                .environment(model)
                .frame(minWidth: 640, minHeight: 380)
                .background(WindowAttacher())
        }
        .defaultSize(width: 1040, height: 700)
        .windowResizability(.contentMinSize)
        .commands { AppCommands(model: model) }
    }
}

/// 把 SwiftUI 建好的 NSWindow 交給 FileTidyIntegration
private struct WindowAttacher: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            MainActor.assumeIsolated {
                FileTidyIntegration.window = w
                // 等 SwiftUI 設好自己的代理再包上去
                DispatchQueue.main.async {
                    guard !(w.delegate is FileTidyIntegration.HideOnCloseDelegate) else { return }
                    let d = FileTidyIntegration.HideOnCloseDelegate(original: w.delegate)
                    FileTidyIntegration.closeDelegate = d
                    w.delegate = d
                }
                if FileTidyIntegration.closeWindowOnAttach {
                    FileTidyIntegration.closeWindowOnAttach = false
                    DispatchQueue.main.async { FileTidyIntegration.hide(w) }
                } else {
                    NSApp.setActivationPolicy(.regular)
                }
            }
        }
    }
    func makeNSView(context: Context) -> Probe {
        // 記下 openWindow:之後視窗關掉了,選單列、Dock、「在 Finder 中顯示」還能把它開回來
        let open = context.environment.openWindow
        FileTidyIntegration.openWindow = { open(id: FileTidyIntegration.windowID) }
        return Probe()
    }
    func updateNSView(_ nsView: Probe, context: Context) {}
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            let hasSelection = !model.effectiveSelection.isEmpty
            Button("新增資料夾") { model.newFolder() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("以選取項目建立新資料夾") { model.newFolderWithSelection() }
                .keyboardShortcut("n", modifiers: [.command, .control]).disabled(!hasSelection)
            Button("新增分頁") { model.newTab() }.keyboardShortcut("t")
            Divider()
            Button("開啟") { model.openSelection() }.keyboardShortcut("o").disabled(!hasSelection)
            Menu("開啟方式") {
                if let url = model.effectiveSelection.first, model.effectiveSelection.count == 1 {
                    ForEach(model.openWithApps(for: url), id: \.url) { app in
                        Button(app.name) { model.open(url, with: app.url) }
                    }
                }
            }
            .disabled(model.effectiveSelection.count != 1)
            Button("關閉分頁") { model.closeTab(model.activeID) }.keyboardShortcut("w")
            Divider()
            Button("分析資料夾內容…") { model.analyzeSelectionOrCurrent() }
            Button("加到側邊欄") { model.addSelectionToSidebar() }.keyboardShortcut("t", modifiers: [.command, .control])
            Button("取得資訊") { model.showInfo() }.keyboardShortcut("i").disabled(!hasSelection)
            Button("重新命名") { model.renameSelection() }.disabled(!hasSelection)
            Button("壓縮") { model.compressSelection() }.disabled(!hasSelection)
            Button("製作副本") { model.tab.selection = Set(model.effectiveSelection); model.duplicateSelection() }
                .keyboardShortcut("d").disabled(!hasSelection)
            Button("製作替身") { model.makeAlias() }.keyboardShortcut("a", modifiers: [.command, .control]).disabled(!hasSelection)
            Button("快速查看") { model.quickLookSelection() }.keyboardShortcut("y").disabled(!hasSelection)
            Divider()
            Button("共用…") { model.shareSelection() }.disabled(!hasSelection)
            Divider()
            Button("在所在資料夾中顯示") { model.showEnclosingFolder() }.keyboardShortcut("r").disabled(!hasSelection)
            Button("取出") { model.ejectSelection() }.keyboardShortcut("e").disabled(!model.canEject)
            Divider()
            Menu("標籤") {
                ForEach(AppModel.colorTags, id: \.name) { tag in
                    Toggle(isOn: Binding(get: { model.selectionHasTag(tag.name) }, set: { _ in model.toggleTag(tag.name) })) {
                        Label(LocalizedStringKey(tag.name), systemImage: "circle.fill")
                            .foregroundStyle(Color(nsColor: tag.color))
                    }
                }
            }
            .disabled(!hasSelection)
            Divider()
            Button("移到垃圾桶") { model.trashFromMenu() }.keyboardShortcut(.delete, modifiers: .command).disabled(!hasSelection)
            Button("放回原處") { model.putBack(model.effectiveSelection) }.disabled(!model.isInTrash || !hasSelection)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("復原檔案操作") { model.undo() }.keyboardShortcut("z")
        }
        CommandGroup(before: .sidebar) {
            ForEach(Array(ViewMode.allCases.enumerated()), id: \.element.id) { i, m in
                Toggle(isOn: Binding(get: { model.viewMode == m }, set: { _ in model.viewMode = m })) {
                    Label(m.title, systemImage: m.symbol)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
            Menu("圖示大小") {
                ForEach(IconSize.allCases) { sz in
                    Toggle(isOn: Binding(get: { model.iconSize == sz }, set: { _ in model.iconSize = sz; model.viewMode = .icons })) {
                        Text(sz.title)
                    }
                }
            }
            Menu("排列方式") { SortMenuItems(model: model) }
            Divider()
        }
        CommandMenu("系統整合") {
            Toggle("登入時自動開啟 LiriOS", isOn: Binding(
                get: { model.launchAtLogin }, set: { _ in model.toggleLaunchAtLogin() }))
            Toggle("登入時不顯示視窗(背景待命)", isOn: Binding(
                get: { model.hideAtLogin }, set: { model.hideAtLogin = $0 }))
            Divider()
            Button("隱藏 Finder") { FinderControl.hide() }
            Toggle("啟動時自動隱藏 Finder", isOn: Binding(get: { model.hideFinderOnLaunch }, set: { model.hideFinderOnLaunch = $0 }))
            Divider()
            Button(model.viewerIsDefault ? String(localized: "LiriOS 目前是預設檔案檢視器") : String(localized: "設為預設檔案檢視器…")) {
                model.enableViewerDefault()
            }
            .disabled(model.viewerIsDefault)
            Button("還原為 Finder") { model.disableViewerDefault() }
                .disabled(!model.viewerIsDefault)
            Divider()
            Menu {
                ForEach(LanguageSettings.options) { opt in
                    Toggle(isOn: Binding(get: { LanguageSettings.isSelected(opt.code) }, set: { _ in LanguageSettings.set(opt.code) })) {
                        if opt.code == nil { Text("跟隨系統") } else { Text(verbatim: opt.nativeName) }
                    }
                }
            } label: { Text(verbatim: "語言 / Language / 言語") }
        }
        CommandMenu("前往") {
            Button("返回") { model.tab.goBack() }.keyboardShortcut("[")
            Button("下一頁") { model.tab.goForward() }.keyboardShortcut("]")
            Button("上層資料夾") { model.tab.goUp() }.keyboardShortcut(.upArrow)
            Divider()
            Button("搜尋") { model.focusSearch() }.keyboardShortcut("f")
            Button("顯示/隱藏隱藏檔") { model.toggleHidden() }.keyboardShortcut(".", modifiers: [.command, .shift])
            Button("重建索引") { model.rebuildIndex() }
            Divider()
            ForEach(Array(model.places.prefix(8).enumerated()), id: \.offset) { i, place in
                Button(place.name) { model.open(place.url) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option])
            }
        }
    }
}

enum SideTarget: Hashable {
    case folder(URL)
    case tool(Mode)
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool
    @State private var dropHover: URL?
    @State private var addHover = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            VStack(spacing: 0) {
                if model.mode == .browse { TabBar() }
                content
            }
            // 底部的路徑列與狀態列:浮在內容上方的玻璃面板,內容可以捲到它的下面
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomPanel }
            .toolbar { toolbarContent }
            .toolbar(removing: .title)
            .searchable(text: $model.query, placement: .toolbar, prompt: Text("搜尋"))
            .searchScopes(searchScope) {
                Text("整台 Mac").tag(SearchScope.everywhere)
                Text("此資料夾").tag(SearchScope.folder)
            }
            .searchFocused($searchFocused)
            .onChange(of: model.query) { model.queryChanged() }
        }
        .onChange(of: model.focusSearchTick) { searchFocused = true }
        .sheet(item: $model.infoTarget) { InfoSheet(url: $0) }
        .sheet(item: $model.analysisTarget) { FolderAnalysisSheet(request: $0) }
        .sheet(item: $model.sidebarEditTarget) { SidebarEntryEditor(entryID: $0.id) }
        .sheet(isPresented: $model.showSidebarCustomize) { SidebarCustomizeSheet() }
        .confirmationDialog("永久刪除 \(model.pendingDelete?.count ?? 0) 個項目?", isPresented: Binding(
            get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } }), titleVisibility: .visible) {
            Button("永久刪除", role: .destructive) {
                if let urls = model.pendingDelete { model.deletePermanently(urls) }
                model.pendingDelete = nil
            }
            Button("取消", role: .cancel) { model.pendingDelete = nil }
        } message: {
            Text("這些項目會直接從磁碟移除,無法復原。")
        }
        .confirmationDialog("清空垃圾桶?", isPresented: $model.confirmEmptyTrash, titleVisibility: .visible) {
            Button("清空垃圾桶", role: .destructive) { model.emptyTrash() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("垃圾桶裡的所有項目會永久刪除,無法復原。")
        }
    }

    // MARK: 側邊欄

    private var sidebar: some View {
        @Bindable var model = model
        let selection = Binding<SideTarget?>(
            get: { model.mode == .browse ? .folder(model.currentFolder) : .tool(model.mode) },
            set: { t in
                switch t {
                case .folder(let u): model.open(u)
                case .tool(let m): model.mode = m
                case nil: break
                }
            })
        let list = List(selection: selection) {
            SwiftUI.Section("位置") {
                ForEach(model.places) { place in dropRow(place) }
                    .onMove { model.moveSidebar(from: $0, to: $1) }
                addFolderRow
            }
            if model.sidebar.showVolumes {
                SwiftUI.Section("磁碟") {
                    ForEach(model.volumes) { place in dropRow(place) }
                }
            }
            if model.sidebar.showTools {
                SwiftUI.Section("整理工具") {
                    ForEach(Mode.tools) { Label($0.title, systemImage: $0.icon).tag(SideTarget.tool($0)) }
                }
            }
        }
        return VStack(spacing: 0) {
            list
            HStack {
                Menu {
                    Button("加入資料夾…") { model.addSidebarFolderViaPanel() }
                    Button("自訂側邊欄…") { model.showSidebarCustomize = true }
                    Divider()
                    Button("還原預設側邊欄", role: .destructive) { model.sidebar.restoreDefaults() }
                } label: { Image(systemName: "slider.horizontal.3").frame(width: 30, height: 30).contentShape(Circle()) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .glassEffect(.regular.interactive(), in: .circle)
                .help("自訂側邊欄")
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    /// 「加入資料夾…」:點一下開啟選擇視窗;也可以直接把資料夾拖到這一列
    private var addFolderRow: some View {
        Button { model.addSidebarFolderViaPanel() } label: {
            Label("加入資料夾…", systemImage: "plus.circle").foregroundStyle(.secondary).font(.callout)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .background(addHover ? Color.accentColor.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .onDrop(of: [.fileURL], delegate: SidebarAddDropDelegate(model: model, hovered: $addHover))
        .help("點一下選擇資料夾,或把資料夾拖到這裡")
    }

    /// 側邊欄的位置項目:可點選,也可以把檔案拖放上去
    private func dropRow(_ place: Place) -> some View {
        Label(place.name, systemImage: place.icon)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 1)
            .background(dropHover == place.url ? Color.accentColor.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .onDrop(of: [.fileURL], delegate: FolderDropDelegate(model: model, target: place.url, hovered: $dropHover))
            .opacity(place.missing ? 0.5 : 1)
            .help(place.missing ? String(localized: "找不到這個資料夾") : place.url.path)
            .contextMenu {
                Button("在新分頁開啟") { model.newTab(place.url) }.disabled(place.missing)
                if let id = place.entryID {
                    Divider()
                    Button("編輯名稱與圖示…") { model.sidebarEditTarget = SidebarEditRequest(id: id) }
                    Button("從側邊欄移除", role: .destructive) { model.sidebar.remove(id) }
                }
            }
            .tag(SideTarget.folder(place.url))
    }

    // MARK: 工具列(導覽 + 路徑 + 搜尋)

    enum SearchScope: Hashable { case everywhere, folder }

    /// 搜尋範圍(系統搜尋欄下方的範圍選擇)
    private var searchScope: Binding<SearchScope> {
        Binding(
            get: { model.searchAllMac ? .everywhere : .folder },
            set: { new in
                let all = new == .everywhere
                guard model.searchAllMac != all else { return }
                model.searchAllMac = all
                if !model.query.isEmpty { model.runSearch() }
            })
    }

    /// 原生工具列:系統會自動套用 Liquid Glass(按鈕群組、分段控制項都是玻璃)
    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        @Bindable var model = model
        if model.mode == .browse {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.tab.goBack() } label: { Label("返回", systemImage: "chevron.left") }.disabled(!model.tab.canGoBack)
                Button { model.tab.goForward() } label: { Label("下一頁", systemImage: "chevron.right") }.disabled(!model.tab.canGoForward)
                Button { model.tab.goUp() } label: { Label("上層資料夾", systemImage: "arrow.up") }.disabled(!model.tab.canGoUp)
            }
            ToolbarItem(placement: .principal) {
                PathBar().frame(minWidth: 160, idealWidth: 420, maxWidth: 560)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isInTrash {
                    Button("清空垃圾桶…", role: .destructive) { model.confirmEmptyTrash = true }.disabled(model.tab.items.isEmpty)
                }
                Picker("顯示方式", selection: $model.viewMode) {
                    ForEach(ViewMode.allCases) { m in Label(m.title, systemImage: m.symbol).tag(m) }
                }
                .pickerStyle(.segmented)
                .help("顯示方式")
                Menu {
                    SortMenuItems(model: model)
                } label: {
                    Label("排列方式", systemImage: "arrow.up.arrow.down")
                }
                .help("排列方式:\(model.sortKey.title)")
            }
        } else {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Text(model.mode.title).font(.headline)
                    Text(model.currentFolder.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.mode {
        case .browse:
            if model.query.trimmingCharacters(in: .whitespaces).isEmpty { BrowserView() } else { SearchResultsView() }
        case .organize: OrganizeView()
        case .duplicates: DuplicatesView()
        case .rename: RenameView()
        case .disk: DiskView()
        case .history: HistoryView()
        }
    }

    /// 選取項目的完整路徑 + 狀態列,合成一個浮動的玻璃面板
    private var bottomPanel: some View {
        VStack(spacing: 2) {
            if let selected = model.selectedPathURL { PathCrumbBar(url: selected) }
            statusBar
        }
        .padding(.vertical, 4)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .padding(.top, 4)
    }

    private var statusBar: some View {
        HStack {
            Text(model.status.isEmpty ? itemSummary : model.status).lineLimit(1)
            Spacer()
            if model.busy { ProgressView().controlSize(.mini) }
            Text(model.phaseText)
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 3)
    }

    private var itemSummary: String {
        guard model.mode == .browse else { return "" }
        let sel = model.tab.selection.count
        return sel > 0 ? String(localized: "已選擇 \(sel) 個,共 \(model.tab.items.count) 個項目") : String(localized: "\(model.tab.items.count) 個項目")
    }
}

/// 排列方式選單(工具列按鈕與「顯示方式」選單共用):依什麼排、方向、資料夾是否在前
struct SortMenuItems: View {
    let model: AppModel

    var body: some View {
        ForEach(AppModel.SortKey.allCases) { key in
            Toggle(isOn: Binding(get: { model.sortKey == key }, set: { _ in model.sort(by: key) })) {
                Text(key.title)
            }
        }
        Divider()
        Toggle("遞增", isOn: Binding(get: { model.sortAscending }, set: { _ in model.setSortAscending(true) }))
        Toggle("遞減", isOn: Binding(get: { !model.sortAscending }, set: { _ in model.setSortAscending(false) }))
        Divider()
        Toggle("資料夾排在最前面", isOn: Binding(get: { model.foldersFirst }, set: { model.foldersFirst = $0 }))
    }
}

struct TabBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(model.tabs) { t in
                    let active = t.id == model.activeID
                    HStack(spacing: 5) {
                        Image(systemName: "folder").font(.caption)
                        Text(t.title).lineLimit(1)
                        if model.tabs.count > 1 {
                            Button { model.closeTab(t.id) } label: { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .glassEffect(active ? .regular.tint(Color.accentColor.opacity(0.35)).interactive() : .regular.interactive(), in: .capsule)
                    .contentShape(Capsule())
                    .onTapGesture { model.activeID = t.id; model.clearSearch() }
                }
                Button { model.newTab() } label: { Image(systemName: "plus").padding(7) }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                Spacer()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

struct PathBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let comps = pathComponents(model.currentFolder)
        let row = HStack(spacing: 2) {
            ForEach(Array(comps.enumerated()), id: \.offset) { i, c in
                if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                Button { model.open(c.url) } label: { Text(c.name).lineLimit(1).fixedSize() }
                    .fontWeight(i == comps.count - 1 ? .semibold : .regular)
            }
        }
        // 放得下就置中顯示;太長時改成可捲動並停在最後幾層
        ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: false) { row }
                .defaultScrollAnchor(.trailing)
        }
        .frame(minWidth: 60)
    }

    private func pathComponents(_ url: URL) -> [(name: String, url: URL)] {
        var out: [(String, URL)] = []
        var cur = url.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        while true {
            if cur == home { out.append((String(localized: "個人"), cur)); break }
            if cur.path == "/" { out.append(("Macintosh HD", cur)); break }
            out.append((cur.lastPathComponent == ".Trash" ? String(localized: "垃圾桶") : cur.lastPathComponent, cur))
            cur.deleteLastPathComponent()
        }
        return out.reversed()
    }
}
