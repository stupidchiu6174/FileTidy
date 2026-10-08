import Foundation

public struct FolderUsage: Identifiable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let bytes: Int64
    public let fileCount: Int
    public var name: String { url.lastPathComponent }
}

public struct DiskReport: Sendable {
    public let totalBytes: Int64
    public let folders: [FolderUsage]
    public let largestFiles: [FileEntry]
}

public enum DiskAnalyzer {
    public static func analyze(entries: [FileEntry], root: URL, topFiles: Int = 50) -> DiskReport {
        let rootPath = root.standardizedFileURL.path
        var sizes: [String: (Int64, Int)] = [:]
        var total: Int64 = 0

        for e in entries {
            total += e.size
            let path = e.url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let rest = path.dropFirst(rootPath.count + 1)
            // 直接放在根目錄的檔案歸在「(根目錄檔案)」,其餘依第一層資料夾加總
            let key = rest.contains("/") ? String(rest.prefix { $0 != "/" }) : ""
            let old = sizes[key] ?? (0, 0)
            sizes[key] = (old.0 + e.size, old.1 + 1)
        }

        let folders = sizes.map { key, v in
            FolderUsage(url: key.isEmpty ? root : root.appendingPathComponent(key, isDirectory: true),
                        bytes: v.0, fileCount: v.1)
        }.sorted { $0.bytes > $1.bytes }

        return DiskReport(totalBytes: total, folders: folders,
                          largestFiles: Array(entries.sorted { $0.size > $1.size }.prefix(topFiles)))
    }
}
