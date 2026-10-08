import SwiftUI
import AppKit
import FileTidyCore

/// 預覽欄與圖庫右側資訊面板共用:種類、大小、日期、標籤。
struct FileInfoGrid: View {
    let url: URL

    private var values: URLResourceValues? {
        try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .isDirectoryKey, .isPackageKey, .fileSizeKey,
                                          .creationDateKey, .contentModificationDateKey, .contentAccessDateKey, .tagNamesKey])
    }

    var body: some View {
        let v = values
        let isFolder = (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            row("種類", v?.localizedTypeDescription ?? "—")
            if !isFolder { row("大小", formatBytes(Int64(v?.fileSize ?? 0))) }
            row("建立日期", date(v?.creationDate))
            row("修改日期", date(v?.contentModificationDate))
            row("上次開啟", date(v?.contentAccessDate))
            if let tags = v?.tagNames, !tags.isEmpty { row("標籤", tags.joined(separator: String(localized: "、"))) }
        }
        .font(.callout)
    }

    @ViewBuilder private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).lineLimit(2)
        }
    }

    private func date(_ d: Date?) -> String { d?.formatted(date: .abbreviated, time: .shortened) ?? "—" }
}

/// 判斷一個路徑是不是「可進入的資料夾」(套件如 .app 視為檔案)
func isBrowsableFolder(_ url: URL) -> Bool {
    let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
    return (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
}
