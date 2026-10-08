import SwiftUI
import AppKit

/// 選取項目時顯示在視窗底部的完整路徑(Finder 的「顯示路徑列」)。
/// 每一層都可以點擊跳過去;最後一層(被選取的項目)會跳到它所在的資料夾並選取它。
struct PathCrumbBar: View {
    @Environment(AppModel.self) private var model
    let url: URL

    private var crumbs: [URL] {
        var list: [URL] = []
        var cur = url.standardizedFileURL
        while true {
            list.append(cur)
            if cur.path == "/" { break }
            cur.deleteLastPathComponent()
        }
        return list.reversed()
    }

    var body: some View {
        let items = crumbs
        GeometryReader { geo in
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, c in
                    if i > 0 { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary) }
                    Button { go(c, isLast: i == items.count - 1) } label: {
                        HStack(spacing: 3) {
                            Image(nsImage: icon(for: c)).resizable().frame(width: 13, height: 13)
                            Text(name(c)).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .fontWeight(i == items.count - 1 ? .semibold : .regular)
                    .help(c.path)
                }
            }
            .padding(.horizontal, 12)
            .frame(minWidth: geo.size.width, alignment: .leading)  // 短路徑靠左
        }
        .defaultScrollAnchor(.trailing)  // 路徑太長放不下時,優先看到最後幾層
        }
        .frame(height: 22)
        .contextMenu {
            Button("拷貝路徑") { model.copyPath([url]) }
            Button("在新分頁中顯示所在位置") { model.newTab(url.deletingLastPathComponent()) }
        }
    }

    private func name(_ u: URL) -> String { u.path == "/" ? "Macintosh HD" : u.lastPathComponent }

    private func icon(for u: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: u.path)
    }

    private func go(_ target: URL, isLast: Bool) {
        if isLast {
            var isDir: ObjCBool = false
            let pkg = (try? target.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
            if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue, !pkg {
                model.open(target)
            } else {
                model.open(target.deletingLastPathComponent(), select: target)
            }
        } else {
            model.open(target)
        }
    }
}
