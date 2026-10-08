import SwiftUI
import AppKit
import FileTidyCore

/// 「圖庫」顯示:上方是選取項目的大預覽,右邊是資訊,下方是縮圖列。
struct GalleryView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        let tab = model.tab
        let items = tab.sortedItems
        let current: DirItem? = items.first(where: { tab.selection.contains($0.url) }) ?? items.first

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if let current {
                    GalleryPreview(url: current.url, isFolder: current.isBrowsable, isPackage: current.isPackage)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onTapGesture(count: 2) { model.activate(current.url) }
                    Divider()
                    inspector(current)
                } else {
                    Text("空的資料夾").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            filmstrip(items: items, currentURL: current?.url)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { if tab.selection.isEmpty, let f = items.first { tab.selection = [f.url] } }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            step(press.key, items: items, current: current?.url); return .handled
        }
        .onKeyPress(.space) {
            guard let c = current else { return .ignored }
            model.quickLookURL = c.url; return .handled
        }
        .onKeyPress(.return) {
            guard let c = current else { return .ignored }
            model.renameTarget = c.url; return .handled
        }
        .onCopyCommand {
            model.copyToPasteboard(model.selectionURLs)
            return model.selectionURLs.map { NSItemProvider(object: $0 as NSURL) }
        }
        .onPasteCommand(of: [.fileURL]) { _ in model.paste() }
        .onDeleteCommand { model.trashSelection() }
        .contextMenu { BrowseContextMenu(sel: []) }
    }

    // MARK: 右側資訊

    private func inspector(_ item: DirItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(nsImage: Icons.icon(for: item)).resizable().frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.headline).lineLimit(3).textSelection(.enabled)
                        Text(item.kind).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Text("資訊").font(.subheadline.bold())
                FileInfoGrid(url: item.url)
            }
            .padding(14)
        }
        .frame(width: 260)
    }

    // MARK: 縮圖列

    private func filmstrip(items: [DirItem], currentURL: URL?) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 8) {
                    ForEach(items) { item in
                        let selected = item.url == currentURL
                        FileIconView(url: item.url, isFolder: item.isBrowsable, isPackage: item.isPackage, points: 64)
                            .padding(5)
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3))
                            .background(selected ? Color.accentColor.opacity(0.12) : .clear,
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .contentShape(Rectangle())
                            .help(item.name)
                            .id(item.url)
                            .overlay {
                                FileDragOverlay(
                                    url: item.url,
                                    selectedURLs: { [item.url] },
                                    onMouseDown: { _ in focused = true; model.tab.selection = [item.url] },
                                    onPlainClick: {},
                                    onContextClick: { model.tab.selection = [item.url] },
                                    onActivate: { model.activate(item.url) },
                                    iconPoints: 64)
                            }
                            .contextMenu { BrowseContextMenu(sel: [item.url]) }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .frame(height: 96)
            .onChange(of: currentURL) { _, new in
                if let new { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(new, anchor: .center) } }
            }
        }
    }

    private func step(_ key: KeyEquivalent, items: [DirItem], current: URL?) {
        guard !items.isEmpty else { return }
        let i = items.firstIndex(where: { $0.url == current }) ?? 0
        let delta = (key == .leftArrow || key == .upArrow) ? -1 : 1
        model.tab.selection = [items[min(max(i + delta, 0), items.count - 1)].url]
    }
}

/// 大預覽:產生高解析縮圖,產生前先顯示通用圖示
private struct GalleryPreview: View {
    let url: URL
    let isFolder: Bool
    let isPackage: Bool
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { geo in
            let side = max(120, min(geo.size.width, geo.size.height) - 48)
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                        .padding(24)
                } else {
                    Image(nsImage: Icons.icon(url: url, isFolder: isFolder, isPackage: isPackage))
                        .resizable().scaledToFit().frame(width: side * 0.6, height: side * 0.6)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .task(id: url) {
                image = nil
                guard !isFolder, !isPackage else { return }
                image = await Thumbs.thumbnail(for: url, points: 640)
            }
        }
    }
}
