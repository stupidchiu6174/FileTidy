import Foundation

/// 一個資料夾的分析結果:規模、內容構成、最大/最近的檔案、子資料夾占比、偵測到的專案類型。
public struct FolderAnalysis: Codable, Sendable, Equatable {
    public struct Category: Codable, Sendable, Equatable { public var id: String; public var count: Int; public var bytes: Int64 }
    public struct Ext: Codable, Sendable, Equatable { public var ext: String; public var count: Int; public var bytes: Int64 }
    public struct AnalyzedFile: Codable, Sendable, Equatable { public var relativePath: String; public var size: Int64; public var modified: Date }
    public struct Child: Codable, Sendable, Equatable { public var name: String; public var isDirectory: Bool; public var bytes: Int64; public var fileCount: Int }

    public var path: String
    public var analyzedAt: Date
    public var fileCount = 0
    public var folderCount = 0
    public var totalBytes: Int64 = 0
    public var hiddenCount = 0
    public var emptyFileCount = 0
    public var maxDepth = 0
    public var oldest: Date?
    public var newest: Date?
    /// 檔案太多,只分析了前面一部分
    public var truncated = false
    /// 為了速度而「沒有進入」的大型依賴資料夾(node_modules、.git…)
    public var skippedDirs: [String] = []
    public var categories: [Category] = []
    public var extensions: [Ext] = []
    public var largest: [AnalyzedFile] = []
    public var recent: [AnalyzedFile] = []
    public var children: [Child] = []
    /// 偵測到的專案類型 id(見 `FolderAnalysis.projectName`)
    public var projects: [String] = []
    /// 裝置端 AI 寫的摘要(有產生過才有),跟著分析結果一起保存
    public var aiSummary: String?

    public init(path: String, analyzedAt: Date = Date()) {
        self.path = path
        self.analyzedAt = analyzedAt
    }

    public var isEmpty: Bool { fileCount == 0 && folderCount == 0 }
    public var folderName: String { (path as NSString).lastPathComponent }
}

public enum FolderAnalyzer {
    /// 這些資料夾內容量大、對「裡面裝了什麼」幾乎沒有資訊,不進入,只記錄它存在
    static let opaqueDirs: Set<String> = [
        "node_modules", ".git", ".build", "DerivedData", "Pods", ".venv", "venv", "__pycache__", ".gradle", ".cache", ".Trash",
    ]

    /// 檔名(小寫)→ 專案類型
    static let markerNames: [String: String] = [
        "package.swift": "swiftpm", ".git": "git", "package.json": "node", "requirements.txt": "python",
        "pyproject.toml": "python", "cargo.toml": "rust", "go.mod": "go", "pom.xml": "java", "build.gradle": "java",
        "build.gradle.kts": "java", "dockerfile": "docker", ".obsidian": "obsidian", "cmakelists.txt": "cmake",
    ]
    /// 副檔名(小寫)→ 專案類型
    static let markerExts: [String: String] = ["xcodeproj": "xcode", "xcworkspace": "xcode", "blend": "blender", "unitypackage": "unity"]

    /// 掃描並分析。被取消時回傳 nil。progress 約每 2000 個項目回報一次。
    public static func analyze(_ root: URL, maxEntries: Int = 400_000,
                               progress: ((Int) -> Void)? = nil, isCancelled: () -> Bool = { false }) -> FolderAnalysis? {
        let canonicalRoot = canonicalPath(root.path)
        var a = FolderAnalysis(path: root.path)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: canonicalRoot), includingPropertiesForKeys: keys,
                                                     options: [.skipsPackageDescendants]) else { return a }

        var catMap: [FileCategory: (count: Int, bytes: Int64)] = [:]
        var extMap: [String: (count: Int, bytes: Int64)] = [:]
        var childMap: [String: FolderAnalysis.Child] = [:]
        var markers: [String] = []          // 依出現順序,去重
        var skipped: [String] = []
        var largest: [FolderAnalysis.AnalyzedFile] = []
        var recent: [FolderAnalysis.AnalyzedFile] = []
        var seen = 0
        let prefixLength = canonicalRoot.count + 1

        func addMarker(_ id: String) { if !markers.contains(id) { markers.append(id) } }

        while let url = e.nextObject() as? URL {
            if isCancelled() { return nil }
            seen += 1
            if seen % 2000 == 0 { progress?(seen) }
            if seen > maxEntries { a.truncated = true; break }

            let name = url.lastPathComponent
            let path = url.path
            guard path.count > prefixLength else { continue }
            let rel = String(path.dropFirst(prefixLength))
            let comps = rel.split(separator: "/")
            a.maxDepth = max(a.maxDepth, comps.count)
            if name.hasPrefix(".") { a.hiddenCount += 1 }

            let lower = name.lowercased()
            if let id = markerNames[lower] { addMarker(id) }
            if let id = markerExts[(lower as NSString).pathExtension] { addMarker(id) }
            if lower == "projectversion.txt", rel.lowercased().hasSuffix("projectsettings/projectversion.txt") { addMarker("unity") }

            let v = try? url.resourceValues(forKeys: Set(keys))
            let isDir = v?.isDirectory ?? false, isPkg = v?.isPackage ?? false

            if isDir && !isPkg {
                a.folderCount += 1
                if opaqueDirs.contains(name) {
                    e.skipDescendants()
                    if !skipped.contains(name) { skipped.append(name) }
                }
                if comps.count == 1 { childMap[name] = FolderAnalysis.Child(name: name, isDirectory: true, bytes: 0, fileCount: 0) }
                continue
            }

            // 檔案(套件如 .app 也當成一個檔案,大小另外加總)
            let size = isPkg ? packageSize(url, isCancelled: isCancelled) : Int64(v?.fileSize ?? 0)
            let modified = v?.contentModificationDate ?? .distantPast
            a.fileCount += 1
            a.totalBytes += size
            if size == 0 && !isPkg { a.emptyFileCount += 1 }
            if modified != .distantPast {
                a.oldest = min(a.oldest ?? modified, modified)
                a.newest = max(a.newest ?? modified, modified)
            }
            let ext = (lower as NSString).pathExtension
            let cat = FileCategory.of(ext: ext)
            catMap[cat, default: (0, 0)].count += 1
            catMap[cat, default: (0, 0)].bytes += size
            let extKey = ext.isEmpty ? "" : ext
            extMap[extKey, default: (0, 0)].count += 1
            extMap[extKey, default: (0, 0)].bytes += size

            let item = FolderAnalysis.AnalyzedFile(relativePath: rel, size: size, modified: modified)
            insertTop(&largest, item, limit: 10) { $0.size > $1.size }
            insertTop(&recent, item, limit: 8) { $0.modified > $1.modified }

            let top = String(comps[0])
            var child = childMap[top] ?? FolderAnalysis.Child(name: top, isDirectory: comps.count > 1, bytes: 0, fileCount: 0)
            child.bytes += size
            child.fileCount += 1
            childMap[top] = child
        }

        a.categories = catMap.map { FolderAnalysis.Category(id: $0.key.rawValue, count: $0.value.count, bytes: $0.value.bytes) }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.count > $1.count }
        a.extensions = extMap.map { FolderAnalysis.Ext(ext: $0.key, count: $0.value.count, bytes: $0.value.bytes) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.bytes > $1.bytes }
            .prefix(12).map { $0 }
        a.children = childMap.values.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }.prefix(12).map { $0 }
        a.largest = largest
        a.recent = recent
        a.skippedDirs = skipped
        a.projects = markers
        return a
    }

    /// 維持一個固定長度的「前 N 名」清單
    private static func insertTop(_ list: inout [FolderAnalysis.AnalyzedFile], _ item: FolderAnalysis.AnalyzedFile, limit: Int,
                                  _ before: (FolderAnalysis.AnalyzedFile, FolderAnalysis.AnalyzedFile) -> Bool) {
        if list.count == limit, let last = list.last, !before(item, last) { return }
        let idx = list.firstIndex(where: { before(item, $0) }) ?? list.count
        list.insert(item, at: idx)
        if list.count > limit { list.removeLast() }
    }

    /// .app、.photoslibrary 等套件:加總裡面檔案的大小(有上限,避免超大的照片庫拖慢整個分析)
    private static func packageSize(_ url: URL, cap: Int = 50_000, isCancelled: () -> Bool) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []) else { return 0 }
        var total: Int64 = 0, n = 0
        while let u = e.nextObject() as? URL {
            n += 1
            if n > cap || (n % 500 == 0 && isCancelled()) { break }
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }
}

// MARK: - 白話摘要(不需要任何 AI,隨介面語言)

extension FolderAnalysis {
    public static func projectName(_ id: String) -> String {
        switch id {
        case "swiftpm": String(localized: "Swift 套件")
        case "git": String(localized: "Git 版本庫")
        case "xcode": String(localized: "Xcode 專案")
        case "node": String(localized: "Node.js 專案")
        case "python": String(localized: "Python 專案")
        case "rust": String(localized: "Rust 專案")
        case "go": String(localized: "Go 專案")
        case "java": String(localized: "Java / Gradle 專案")
        case "unity": String(localized: "Unity 專案")
        case "blender": String(localized: "Blender 檔案")
        case "docker": String(localized: "Docker 設定")
        case "obsidian": String(localized: "Obsidian 筆記庫")
        case "cmake": String(localized: "CMake 專案")
        default: id
        }
    }

    /// 一段說明這個資料夾裡裝了什麼的文字
    public func summaryText() -> String {
        if isEmpty { return String(localized: "這個資料夾是空的。") }
        var parts: [String] = []

        parts.append(String(localized: "「\(folderName)」共有 \(fileCount.formatted()) 個檔案、\(folderCount.formatted()) 個資料夾,合計 \(formatBytes(totalBytes))。"))

        if let top = categories.first, let cat = FileCategory(rawValue: top.id) {
            let share = totalBytes > 0 ? Int(Double(top.bytes) / Double(totalBytes) * 100) : Int(Double(top.count) / Double(max(fileCount, 1)) * 100)
            parts.append(String(localized: "內容以「\(cat.title)」為主(\(top.count.formatted()) 個,\(formatBytes(top.bytes)),約占 \(share)%)。"))
            if categories.count > 1, let second = categories.dropFirst().first, let c2 = FileCategory(rawValue: second.id) {
                parts.append(String(localized: "其次是「\(c2.title)」(\(second.count.formatted()) 個)。"))
            }
        }

        if !projects.isEmpty {
            let names = projects.map(Self.projectName).joined(separator: String(localized: "、"))
            parts.append(String(localized: "裡面有開發專案的痕跡:\(names)。"))
        }
        if !skippedDirs.isEmpty {
            parts.append(String(localized: "另外有依賴或快取資料夾(\(skippedDirs.joined(separator: String(localized: "、")))),為了速度沒有逐一統計。"))
        }
        if let big = largest.first, big.size > 0 {
            parts.append(String(localized: "最大的檔案是「\((big.relativePath as NSString).lastPathComponent)」(\(formatBytes(big.size)))。"))
        }
        if let o = oldest, let n = newest {
            parts.append(String(localized: "檔案的修改時間從 \(o.formatted(date: .abbreviated, time: .omitted)) 到 \(n.formatted(date: .abbreviated, time: .omitted))。"))
        }
        if emptyFileCount > 0 {
            parts.append(String(localized: "其中有 \(emptyFileCount.formatted()) 個是 0 位元組的空檔案。"))
        }
        if truncated {
            parts.append(String(localized: "檔案數量很多,這份分析只涵蓋前面的一部分。"))
        }
        // 中日文句子之間不加空格,英文要加(翻譯表裡這個鍵對應不同的分隔符)
        return parts.joined(separator: String(localized: "【句子分隔】"))
    }
}
