import SwiftUI
import AppKit
import FileTidyCore

/// 圖示檢視的一個項目(瀏覽資料夾與搜尋結果共用)
struct GridEntry: Identifiable {
    let url: URL
    let name: String
    let isFolder: Bool
    let isPackage: Bool
    var id: URL { url }
}

/// 各格回報自己在格狀區域裡的位置,框選時用來判斷哪些格子被框到
private struct CellFrameKey: PreferenceKey {
    static var defaultValue: [URL: CGRect] = [:]
    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// 圖示檢視(大 / 中 / 小)。選取、框選、雙擊、拖放、右鍵、鍵盤操作與列表一致。
struct IconGridView<Menu: View>: View {
    @Environment(AppModel.self) private var model
    let entries: [GridEntry]
    @Binding var selection: Set<URL>
    let size: IconSize
    /// 放到空白處時要放進的資料夾(搜尋結果沒有這個概念,傳 nil)
    var dropTarget: URL?
    var allowPaste = true
    let onTrash: ([URL]) -> Void
    @ViewBuilder let menu: (Set<URL>) -> Menu

    @FocusState private var focused: Bool
    @State private var dropHover: URL?
    @State private var columns = 1
    @State private var frames: [URL: CGRect] = [:]
    @State private var band: CGRect?
    @State private var bandBase: Set<URL> = []
    @State private var anchor: URL?

    private let spacing: CGFloat = 8
    private var cellWidth: CGFloat { size.points + (size == .small ? 40 : 36) }
    private var nameFont: Font { size == .large ? .callout : .caption }

    var body: some View {
        GeometryReader { geo in
            let cols = max(1, Int((geo.size.width - 24 + spacing) / (cellWidth + spacing)))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(cellWidth), spacing: spacing), count: cols),
                              alignment: .leading, spacing: 8) {
                        ForEach(entries) { entry in
                            cell(entry, selected: selection.contains(entry.url))
                                .id(entry.url)
                                .background(GeometryReader { g in
                                    Color.clear.preference(key: CellFrameKey.self, value: [entry.url: g.frame(in: .named("grid"))])
                                })
                        }
                    }
                    .padding(12)
                    // 內容至少和視窗一樣高,空白處才都能框選、點一下取消選取
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .topLeading)
                    .background(rubberBand)
                    .overlay(alignment: .topLeading) { bandShape }
                    .coordinateSpace(name: "grid")
                }
                .onPreferenceChange(CellFrameKey.self) { frames = $0 }
                .onChange(of: selection) { _, new in
                    if new.count == 1, let u = new.first, band == nil {
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(u) }
                    }
                }
            }
            .onAppear { columns = cols }
            .onChange(of: cols) { _, new in columns = new }
        }
        .contextMenu { menu([]) }
        .modifier(BackgroundDrop(model: model, target: dropTarget))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            guard model.inlineRenameTarget == nil else { return .ignored }
            move(press.key, extend: press.modifiers.contains(.shift)); return .handled
        }
        .onKeyPress(.space) {
            guard model.inlineRenameTarget == nil, let first = selection.sorted(by: { $0.path < $1.path }).first else { return .ignored }
            model.quickLookURL = first; return .handled
        }
        .onKeyPress(.return) {
            guard model.inlineRenameTarget == nil,
                  let first = selection.sorted(by: { $0.path < $1.path }).first else { return .ignored }
            selection = [first]
            model.inlineRenameTarget = first; return .handled
        }
        .onKeyPress(characters: ["a"], phases: .down) { press in
            guard press.modifiers == .command, model.inlineRenameTarget == nil else { return .ignored }
            selection = Set(entries.map(\.url)); return .handled
        }
        .onCopyCommand {
            let urls = Array(selection)
            model.copyToPasteboard(urls)
            return urls.map { NSItemProvider(object: $0 as NSURL) }
        }
        .onPasteCommand(of: [.fileURL]) { _ in if allowPaste { model.paste() } }
        .onDeleteCommand { if model.inlineRenameTarget == nil { onTrash(Array(selection)) } }
        .overlay { if entries.isEmpty { Text("空的資料夾").foregroundStyle(.secondary) } }
    }

    // MARK: 框選

    /// 空白處的拖曳 = 框選;單純點一下 = 取消選取。格子本身的點擊由 FileDragOverlay 處理,不會到這裡。
    private var rubberBand: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("grid"))
                    .onChanged { g in
                        if band == nil {
                            focused = true
                            let extend = NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift)
                            bandBase = extend ? selection : []
                        }
                        let rect = CGRect(x: min(g.startLocation.x, g.location.x), y: min(g.startLocation.y, g.location.y),
                                          width: abs(g.location.x - g.startLocation.x), height: abs(g.location.y - g.startLocation.y))
                        // 沒移動多少視為單擊,不畫框
                        guard rect.width > 3 || rect.height > 3 else { return }
                        band = rect
                        let hit = Set(frames.filter { $0.value.intersects(rect) }.keys)
                        selection = bandBase.union(hit)
                    }
                    .onEnded { _ in
                        if band == nil, bandBase.isEmpty { selection = [] }  // 單擊空白處
                        band = nil
                        bandBase = []
                    }
            )
    }

    @ViewBuilder private var bandShape: some View {
        if let band {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.accentColor.opacity(0.14))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1))
                .frame(width: band.width, height: band.height)
                .offset(x: band.minX, y: band.minY)
                .allowsHitTesting(false)
        }
    }

    // MARK: 格子

    /// 圖示與檔名各自負責一塊「可點擊/可拖曳」的區域;格子裡其餘的空白處不算,
    /// 點到會當成點空白處(取消選取或開始框選),和 Finder 一致。
    private func hitArea(_ entry: GridEntry, iconPoints: CGFloat, onActivate: @escaping () -> Void) -> some View {
        FileDragOverlay(
            url: entry.url,
            selectedURLs: { Array(selection) },
            onMouseDown: { mods in focused = true; select(entry.url, mods) },
            onPlainClick: { if selection.count > 1 { selection = [entry.url]; anchor = entry.url } },
            onContextClick: { if !selection.contains(entry.url) { selection = [entry.url] } },
            onActivate: onActivate,
            iconPoints: iconPoints)
    }

    @ViewBuilder private func cell(_ entry: GridEntry, selected: Bool) -> some View {
        let hovering = dropHover == entry.url
        let menuSelection = selection.contains(entry.url) ? selection : [entry.url]
        let content = VStack(spacing: 3) {
            // 選取/放下的底色只包住圖示本身(貼身的圓角)
            FileIconView(url: entry.url, isFolder: entry.isFolder, isPackage: entry.isPackage, points: size.points)
                .padding(size == .small ? 3 : 4)
                .background(hovering ? Color.accentColor.opacity(0.3) : (selected ? Color.secondary.opacity(0.25) : .clear),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
                // 雙擊圖示:開啟
                .overlay { hitArea(entry, iconPoints: size.points) { model.activate(entry.url) } }
                .contextMenu { menu(menuSelection) }
            if model.inlineRenameTarget == entry.url {
                InlineRenameField(url: entry.url, font: nameFont)
            } else {
                Text(entry.name)
                    .font(nameFont)
                    .lineLimit(size == .small ? 1 : 2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 5)
                    .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .contentShape(Rectangle())
                    // 雙擊檔名:直接在原地改名(和 Finder 一樣,圖示才是開啟)
                    .overlay {
                        hitArea(entry, iconPoints: 0) {
                            selection = [entry.url]
                            anchor = entry.url
                            model.inlineRenameTarget = entry.url
                        }
                    }
                    .contextMenu { menu(menuSelection) }
            }
        }
        .frame(width: cellWidth)
        .padding(.vertical, 4)
        .help(entry.url.path)

        if entry.isFolder {
            // 資料夾的放下目標維持整格(好瞄準),只有「點擊」的範圍縮小
            content.contentShape(Rectangle())
                .onDrop(of: [.fileURL], delegate: FolderDropDelegate(model: model, target: entry.url, hovered: $dropHover))
        } else {
            content
        }
    }

    // MARK: 選取與鍵盤

    private func select(_ url: URL, _ mods: NSEvent.ModifierFlags) {
        let r = SelectionLogic.click(url, command: mods.contains(.command), shift: mods.contains(.shift),
                                     order: entries.map(\.url), state: .init(selection: selection, anchor: anchor))
        selection = r.selection
        anchor = r.anchor
    }

    /// 方向鍵:左右移動一格,上下移動一列(欄數由目前視窗寬度算出);⇧ 從起點延伸或縮回
    private func move(_ key: KeyEquivalent, extend: Bool) {
        guard !entries.isEmpty else { return }
        let order = entries.map(\.url)
        let state = SelectionLogic.State(selection: selection, anchor: anchor)
        let delta: Int
        switch key {
        case .leftArrow: delta = -1
        case .rightArrow: delta = 1
        case .upArrow: delta = -columns
        default: delta = columns
        }
        let target: URL
        if let cursor = SelectionLogic.cursor(order: order, state: state), let ci = order.firstIndex(of: cursor) {
            target = order[min(max(ci + delta, 0), order.count - 1)]
        } else {
            target = order[delta > 0 ? 0 : order.count - 1]  // 還沒有選取:往後從第一個、往前從最後一個
        }
        let r = SelectionLogic.move(to: target, shift: extend, order: order, state: state)
        selection = r.selection
        anchor = r.anchor
    }
}

/// 圖示檢視的原地改名欄位:預先選取主檔名(不含副檔名);Return 或點別處確定,Esc 取消
private struct InlineRenameField: View {
    @Environment(AppModel.self) private var model
    let url: URL
    let font: Font
    @State private var text = ""
    @State private var textSelection: TextSelection?
    @State private var finished = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, selection: $textSelection)
            .textFieldStyle(.plain)
            .font(font)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 3)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 1.5))
            .focused($focused)
            .onAppear {
                let name = url.lastPathComponent
                text = name
                let ext = url.pathExtension
                let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let baseEnd = !ext.isEmpty && !isFolder
                    ? name.index(name.endIndex, offsetBy: -(ext.count + 1))
                    : name.endIndex
                focused = true
                // 等欄位真的成為焦點後再設選取範圍,否則會被「全選」蓋掉
                DispatchQueue.main.async { textSelection = TextSelection(range: name.startIndex..<baseEnd) }
            }
            .onSubmit { finish(commit: true) }
            .onExitCommand { finish(commit: false) }
            .onChange(of: focused) { _, now in if !now { finish(commit: true) } }
    }

    private func finish(commit: Bool) {
        guard !finished else { return }
        finished = true
        if commit { model.rename(url, to: text) }
        if model.inlineRenameTarget == url { model.inlineRenameTarget = nil }
    }
}

/// 空白處接收拖放(放進目前資料夾);沒有目標資料夾時不接收
private struct BackgroundDrop: ViewModifier {
    let model: AppModel
    let target: URL?

    func body(content: Content) -> some View {
        if let target {
            content.onDrop(of: [.fileURL], delegate: FolderDropDelegate(model: model, target: target, hovered: .constant(nil)))
        } else {
            content
        }
    }
}
