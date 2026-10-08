import SwiftUI
import AppKit
import FileTidyCore

/// 「取得資訊」:名稱、種類、大小、位置、日期、權限、標籤。資料夾的大小在背景計算。
struct InfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    @State private var folderBytes: Int64?
    @State private var folderCount: Int?

    private var attrs: [FileAttributeKey: Any] { (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:] }
    private var values: URLResourceValues? {
        try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .isDirectoryKey, .isPackageKey, .fileSizeKey,
                                          .creationDateKey, .contentModificationDateKey, .contentAccessDateKey, .tagNamesKey])
    }
    private var isFolder: Bool { (values?.isDirectory ?? false) && !(values?.isPackage ?? false) }

    var body: some View {
        let v = values
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent).font(.title3.bold()).textSelection(.enabled).lineLimit(2)
                    Text(v?.localizedTypeDescription ?? "").foregroundStyle(.secondary)
                }
            }
            Divider()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                row("大小", sizeText(v))
                row("位置", url.deletingLastPathComponent().path, selectable: true)
                row("建立日期", date(v?.creationDate))
                row("修改日期", date(v?.contentModificationDate))
                row("上次開啟", date(v?.contentAccessDate))
                row("擁有者", (attrs[.ownerAccountName] as? String) ?? "—")
                row("權限", permissionText())
                let tags = v?.tagNames ?? []
                if !tags.isEmpty { row("標籤", tags.joined(separator: String(localized: "、"))) }
            }
            HStack {
                Spacer()
                Button("好") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.glassProminent)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task(id: url) { await computeFolderSize() }
    }

    @ViewBuilder private func row(_ label: LocalizedStringKey, _ value: String, selectable: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            if selectable { Text(value).textSelection(.enabled).lineLimit(3) } else { Text(value) }
        }
    }

    private func date(_ d: Date?) -> String { d?.formatted(date: .long, time: .shortened) ?? "—" }

    private func sizeText(_ v: URLResourceValues?) -> String {
        if isFolder {
            guard let b = folderBytes else { return String(localized: "計算中…") }
            return String(localized: "\(formatBytes(b)),\(folderCount ?? 0) 個項目")
        }
        let size = Int64(v?.fileSize ?? 0)
        return "\(formatBytes(size)) (\(size.formatted()) bytes)"
    }

    private func permissionText() -> String {
        guard let perm = attrs[.posixPermissions] as? Int else { return "—" }
        func bits(_ n: Int) -> String { (n & 4 != 0 ? "r" : "-") + (n & 2 != 0 ? "w" : "-") + (n & 1 != 0 ? "x" : "-") }
        return bits(perm >> 6) + bits(perm >> 3) + bits(perm) + String(format: "  (%o)", perm)
    }

    private func computeFolderSize() async {
        guard isFolder else { return }
        let target = url
        let (bytes, count) = await Task.detached(priority: .utility) { () -> (Int64, Int) in
            var total: Int64 = 0, n = 0
            let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
            if let e = FileManager.default.enumerator(at: target, includingPropertiesForKeys: keys, options: []) {
                while let u = e.nextObject() as? URL {
                    let v = try? u.resourceValues(forKeys: Set(keys))
                    if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0); n += 1 }
                }
            }
            return (total, n)
        }.value
        folderBytes = bytes; folderCount = count
    }
}
