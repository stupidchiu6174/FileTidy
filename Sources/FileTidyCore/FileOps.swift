import Foundation
import UniformTypeIdentifiers

public struct DirItem: Identifiable, Hashable, Sendable {
    public let url: URL
    public let isDirectory: Bool
    public let isPackage: Bool
    public let size: Int64?
    public let modified: Date?
    public let created: Date?
    public let kind: String

    public var id: URL { url }
    public var name: String { url.lastPathComponent }
    /// 資料夾可「進入」;.app 等套件視為檔案
    public var isBrowsable: Bool { isDirectory && !isPackage }
}

public enum DirectoryLister {
    public static func list(_ dir: URL, showHidden: Bool) throws -> [DirItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey,
                                      .creationDateKey, .localizedTypeDescriptionKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: showHidden ? [] : [.skipsHiddenFiles])
        return urls.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            let isDir = v?.isDirectory ?? false
            return DirItem(url: url, isDirectory: isDir, isPackage: v?.isPackage ?? false,
                           size: isDir ? nil : v?.fileSize.map(Int64.init),
                           modified: v?.contentModificationDate, created: v?.creationDate,
                           kind: v?.localizedTypeDescription ?? "")
        }
    }
}

/// Finder 式的即時操作。全部只產生 plan,交給 Executor 執行並寫入復原紀錄。
public enum FileOps {
    public static func copy(_ sources: [URL], into dir: URL) -> OperationPlan {
        OperationPlan(title: String(localized: "拷貝 \(sources.count) 個項目"), actions: sources.compactMap { src in
            guard !isInside(dir, of: src) else { return nil }
            return PlannedAction(kind: .copy, source: src, destination: dir.appendingPathComponent(src.lastPathComponent))
        })
    }

    public static func move(_ sources: [URL], into dir: URL) -> OperationPlan {
        OperationPlan(title: String(localized: "移動 \(sources.count) 個項目"), actions: sources.compactMap { src in
            guard src.deletingLastPathComponent().standardizedFileURL != dir.standardizedFileURL,
                  !isInside(dir, of: src) else { return nil }
            return PlannedAction(kind: .move, source: src, destination: dir.appendingPathComponent(src.lastPathComponent))
        })
    }

    public static func trash(_ sources: [URL]) -> OperationPlan {
        OperationPlan(title: String(localized: "移到垃圾桶(\(sources.count) 項)"), actions: sources.map { PlannedAction(kind: .trash, source: $0) })
    }

    public static func rename(_ source: URL, to newName: String) -> OperationPlan {
        let dest = source.deletingLastPathComponent().appendingPathComponent(newName)
        return OperationPlan(title: String(localized: "重新命名"), actions: [PlannedAction(kind: .move, source: source, destination: dest)])
    }

    public static func newFolder(in dir: URL, name: String = String(localized: "未命名資料夾")) -> OperationPlan {
        OperationPlan(title: String(localized: "新增資料夾"), actions: [PlannedAction(kind: .mkdir, source: dir, destination: dir.appendingPathComponent(name, isDirectory: true))])
    }

    public static func duplicate(_ sources: [URL]) -> OperationPlan {
        OperationPlan(title: String(localized: "製作副本"), actions: sources.map { src in
            let ext = src.pathExtension
            let name = src.deletingPathExtension().lastPathComponent + String(localized: " 副本") + (ext.isEmpty ? "" : "." + ext)
            return PlannedAction(kind: .copy, source: src, destination: src.deletingLastPathComponent().appendingPathComponent(name))
        })
    }

    /// 不能把資料夾放進自己底下
    static func isInside(_ dir: URL, of src: URL) -> Bool {
        let d = dir.standardizedFileURL.path, s = src.standardizedFileURL.path
        return d == s || d.hasPrefix(s + "/")
    }
}
