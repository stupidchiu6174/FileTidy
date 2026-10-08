import Foundation

public struct FileEntry: Identifiable, Hashable, Sendable {
    public let url: URL
    public let size: Int64
    public let created: Date?
    public let modified: Date
    public var isDirectory = false

    public var id: URL { url }
    public var name: String { url.lastPathComponent }
    public var stem: String { url.deletingPathExtension().lastPathComponent }
    public var ext: String { url.pathExtension.lowercased() }
    public var bestDate: Date { created ?? modified }

    public init(url: URL, size: Int64, created: Date?, modified: Date) {
        self.url = url
        self.size = size
        self.created = created
        self.modified = modified
    }
}

public struct PlannedAction: Identifiable, Sendable {
    public enum Kind: Sendable { case move, copy, trash, mkdir }

    public let id = UUID()
    public let kind: Kind
    public let source: URL
    public let destination: URL?
    public let note: String

    public init(kind: Kind, source: URL, destination: URL? = nil, note: String = "") {
        self.kind = kind
        self.source = source
        self.destination = destination
        self.note = note
    }
}

/// 尚未執行的操作清單。所有功能都只產生 plan,由 Executor 統一套用。
public struct OperationPlan: Sendable {
    public var title: String
    public var actions: [PlannedAction]

    public init(title: String, actions: [PlannedAction]) {
        self.title = title
        self.actions = actions
    }
}

public enum FileScanner {
    public static func scan(_ root: URL, recursive: Bool = true) -> [FileEntry] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: options) else {
            return []
        }
        var result: [FileEntry] = []
        for case let url as URL in enumerator {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            result.append(FileEntry(url: url,
                                    size: Int64(v.fileSize ?? 0),
                                    created: v.creationDate,
                                    modified: v.contentModificationDate ?? .distantPast))
        }
        return result
    }
}

public func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
