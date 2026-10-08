import Foundation

public enum FileCategory: String, CaseIterable, Sendable {
    case images, videos, audio, documents, archives, code, apps, installers, other

    /// 顯示名稱,也是整理時建立的資料夾名稱(會隨介面語言改變)
    public var title: String {
        switch self {
        case .images: String(localized: "圖片")
        case .videos: String(localized: "影片")
        case .audio: String(localized: "音訊")
        case .documents: String(localized: "文件")
        case .archives: String(localized: "壓縮檔")
        case .code: String(localized: "程式碼")
        case .apps: String(localized: "應用程式")
        case .installers: String(localized: "安裝檔")
        case .other: String(localized: "其他")
        }
    }

    private static let table: [FileCategory: Set<String>] = [
        .images: ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "bmp", "svg", "raw", "cr2", "nef", "arw", "dng", "psd"],
        .videos: ["mp4", "mov", "m4v", "avi", "mkv", "wmv", "flv", "webm"],
        .audio: ["mp3", "wav", "aac", "flac", "m4a", "aiff", "ogg", "wma"],
        .documents: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "txt", "md", "rtf", "csv", "epub"],
        .archives: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"],
        .code: ["swift", "py", "js", "ts", "tsx", "jsx", "json", "html", "css", "c", "cpp", "h", "m", "java", "go", "rs", "sh", "yml", "yaml", "blend", "cs"],
        .apps: ["app"],
        .installers: ["dmg", "pkg", "iso"],
    ]

    public static func of(ext: String) -> FileCategory {
        let e = ext.lowercased()
        return table.first { $0.value.contains(e) }?.key ?? .other
    }
}

public enum DateGrouping: String, CaseIterable, Sendable {
    case none, year, yearMonth

    public var title: String {
        switch self {
        case .none: String(localized: "不分日期")
        case .year: String(localized: "依年份")
        case .yearMonth: String(localized: "依年月")
        }
    }
}

public struct ClassifyOptions: Sendable {
    public var grouping: DateGrouping
    public var useCreationDate: Bool

    public init(grouping: DateGrouping = .yearMonth, useCreationDate: Bool = true) {
        self.grouping = grouping
        self.useCreationDate = useCreationDate
    }
}

public enum Classifier {
    public static func plan(entries: [FileEntry], root: URL, options: ClassifyOptions = .init()) -> OperationPlan {
        let calendar = Calendar(identifier: .gregorian)
        var actions: [PlannedAction] = []
        for entry in entries {
            let category = FileCategory.of(ext: entry.ext)
            var folder = root.appendingPathComponent(category.title, isDirectory: true)
            if options.grouping != .none {
                let date = options.useCreationDate ? entry.bestDate : entry.modified
                let c = calendar.dateComponents([.year, .month], from: date)
                let year = String(format: "%04d", c.year ?? 0)
                let sub = options.grouping == .year ? year : String(format: "%@-%02d", year, c.month ?? 0)
                folder.appendPathComponent(sub, isDirectory: true)
            }
            let destination = folder.appendingPathComponent(entry.name)
            if destination.standardizedFileURL == entry.url.standardizedFileURL { continue }
            actions.append(PlannedAction(kind: .move, source: entry.url, destination: destination, note: category.title))
        }
        return OperationPlan(title: String(localized: "自動分類"), actions: actions)
    }
}
