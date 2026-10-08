import Foundation
import CoreServices
import Darwin
import IOKit.ps

/// 以 realpath 取得真實路徑(/var → /private/var),與 FileManager 列舉結果的形式一致。
func canonicalPath(_ path: String) -> String {
    guard let r = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
    defer { free(r) }
    return String(cString: r)
}

// MARK: - 資料結構

public struct CatalogItem: Sendable {
    public let path: String
    let norm: String          // 正規化後的完整檔名(含副檔名)
    public let isDirectory: Bool
    public let size: Int64
    public let modified: Double
    let mask: UInt64          // 字元位元遮罩,用來快速排除不可能的候選
    let parent: Int32         // dirNorms 索引,用來比對「所在資料夾名稱」

    public var name: String { (path as NSString).lastPathComponent }
    public var url: URL { URL(fileURLWithPath: path, isDirectory: isDirectory) }
}

public struct SearchHit: Identifiable, Sendable {
    public var id: String { item.path }
    public let item: CatalogItem
    public let score: Double
    public let lexical: Double
    public let semantic: Double?
}

public enum CatalogPhase: Sendable, Equatable {
    case idle
    case loadingCache
    case crawling(files: Int)
    case ready(files: Int)
    case embedding(done: Int, total: Int)
}

// MARK: - 爬取規則

public enum CrawlRules {
    /// 這些資料夾內容量大、使用者幾乎不會想搜尋,不進入(資料夾本身仍會被索引)
    static let skipDirs: Set<String> = [
        ".git", "node_modules", ".build", "DerivedData", "Pods", ".Trash", "__pycache__",
        ".venv", "venv", ".gradle", ".cache", "Caches", ".npm", ".cargo", ".rustup",
    ]

    /// 全機預設根目錄:家目錄(不含 ~/Library)、/Applications、以及外接磁碟。
    public static func defaultRoots() -> [URL] {
        var roots = [FileManager.default.homeDirectoryForCurrentUser, URL(fileURLWithPath: "/Applications")]
        let vols = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: [.volumeIsRootFileSystemKey],
            options: [.skipsHiddenFiles])) ?? []
        for v in vols where (try? v.resourceValues(forKeys: [.volumeIsRootFileSystemKey]))?.volumeIsRootFileSystem != true {
            roots.append(v)
        }
        return roots
    }

    static func shouldSkipDescending(_ url: URL, homeLibrary: String) -> Bool {
        skipDirs.contains(url.lastPathComponent) || url.path == homeLibrary
    }
}

// MARK: - FSEvents

final class FSEventsWatcher {
    typealias Handler = (_ events: [(path: String, rescanAll: Bool)], _ latestID: UInt64) -> Void
    private var stream: FSEventStreamRef?
    private let handler: Handler
    private let queue = DispatchQueue(label: "filetidy.fsevents")

    init(paths: [String], since: UInt64, handler: @escaping Handler) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, eventIds in
            guard let info, count > 0 else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            var out: [(String, Bool)] = []
            for i in 0..<min(count, paths.count) {
                let rescan = eventFlags[i] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
                out.append((paths[i], rescan))
            }
            watcher.handler(out, eventIds[count - 1])
        }
        stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths as CFArray, since, 3.0,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    var latestID: UInt64 { stream.map { FSEventStreamGetLatestEventId($0) } ?? 0 }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        self.stream = nil
    }
    deinit { stop() }
}

// MARK: - 快取檔

private struct CatalogCache: Codable {
    var roots: [String]
    var eventID: UInt64
    var paths: [String]
    var norms: [String]
    var sizes: [Int64]
    var mods: [Double]
    var dirs: Data
}

private struct VectorCache: Codable {
    var embedder: String
    var dim: Int
    var paths: [String]
    var scales: [Float]
    var blob: Data
}

private struct QuantVec { var scale: Float; var q: [Int8] }

// MARK: - 全機目錄

public actor FileCatalog {
    private var items: [String: CatalogItem] = [:]
    private var children: [String: Set<String>] = [:]
    private var dirNorms: [String] = []
    private var dirIDs: [String: Int32] = [:]
    private var vectors: [String: QuantVec] = [:]

    public let roots: [URL]
    private let cacheDir: URL
    private let homeLibrary: String
    private var watcher: FSEventsWatcher?
    private var embedder: TextEmbedder?
    private var embedderFactory: (([String]) -> TextEmbedder?)?
    private var embedTask: Task<Void, Never>?
    private var pendingRefresh = Set<String>()
    private var refreshScheduled = false
    private var onPhase: (@Sendable (CatalogPhase) -> Void)?
    private var onChange: (@Sendable () -> Void)?
    public private(set) var phase: CatalogPhase = .idle { didSet { onPhase?(phase) } }
    public var count: Int { items.count }
    var itemsView: Dictionary<String, CatalogItem>.Values { items.values }
    public var embedderName: String { embedder?.name ?? String(localized: "未啟用") }

    public init(roots: [URL] = CrawlRules.defaultRoots(), cacheDir: URL? = nil) {
        self.roots = roots.map { URL(fileURLWithPath: canonicalPath($0.path), isDirectory: true) }
        self.cacheDir = cacheDir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FileTidy", isDirectory: true)
        homeLibrary = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
        try? FileManager.default.createDirectory(at: self.cacheDir, withIntermediateDirectories: true)
    }

    public func setObservers(phase: @escaping @Sendable (CatalogPhase) -> Void, change: @escaping @Sendable () -> Void) {
        onPhase = phase
        onChange = change
    }

    // MARK: 啟動

    /// 載入快取 → 用 FSEvents 補上離線期間的變動(沒有快取則完整爬取)→ 開始監看 → 背景建立語意索引
    public func start(semantic: @escaping ([String]) -> TextEmbedder? = { NLSentenceEmbedder.make(forSamples: $0) }) async {
        embedderFactory = semantic
        phase = .loadingCache
        var since = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        if let cache = loadCache(), cache.roots == roots.map(\.path) {
            for (i, p) in cache.paths.enumerated() {
                let isDir = cache.dirs[i / 8] & (1 << UInt8(i % 8)) != 0
                let n = cache.norms[i]
                insert(CatalogItem(path: p, norm: n, isDirectory: isDir, size: cache.sizes[i], modified: cache.mods[i], mask: Self.mask(n), parent: -1))
            }
            since = cache.eventID
            phase = .ready(files: items.count)
            onChange?()
        } else {
            await fullCrawl()
        }
        startWatching(since: since)
        await saveCacheNow()
        beginEmbedding()
    }

    public func rebuild() async {
        embedTask?.cancel()
        watcher?.stop(); watcher = nil
        items = [:]; children = [:]; vectors = [:]
        await fullCrawl()
        startWatching(since: FSEventStreamEventId(kFSEventStreamEventIdSinceNow))
        await saveCacheNow()
        beginEmbedding()
    }

    private func fullCrawl() async {
        phase = .crawling(files: 0)
        let library = homeLibrary
        for root in roots {
            // 每個根目錄的第一層子項分開平行爬取,邊爬邊合併,讓進度可見
            let top = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            insert(makeItem(path: root.path, isDirectory: true, size: 0, modified: 0))
            await withTaskGroup(of: [CatalogItem].self) { group in
                var running = 0
                for url in top {
                    if running >= 6, let batch = await group.next() { merge(batch); running -= 1 }
                    group.addTask { await Self.crawl(url, homeLibrary: library) }
                    running += 1
                }
                for await batch in group { merge(batch) }
            }
        }
        phase = .ready(files: items.count)
        onChange?()
    }

    private func merge(_ batch: [CatalogItem]) {
        for i in batch { insert(i) }
        phase = .crawling(files: items.count)
    }

    // MARK: 爬取(在背景執行,不佔用 actor)

    private static func crawl(_ top: URL, homeLibrary: String) async -> [CatalogItem] {
        await Task.detached(priority: .utility) { crawlSync(top, homeLibrary: homeLibrary) }.value
    }

    private static func crawlSync(_ top: URL, homeLibrary: String) -> [CatalogItem] {
        var out: [CatalogItem] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        func add(_ url: URL, _ v: URLResourceValues?) -> Bool {
            let isDir = (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
            out.append(makeItem(url.path, isDir, Int64(v?.fileSize ?? 0), v?.contentModificationDate?.timeIntervalSince1970 ?? 0))
            return isDir
        }
        guard !top.lastPathComponent.hasPrefix(".") else { return [] }
        let topIsDir = add(top, try? top.resourceValues(forKeys: Set(keys)))
        guard topIsDir, !CrawlRules.shouldSkipDescending(top, homeLibrary: homeLibrary),
              let e = FileManager.default.enumerator(at: top, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return out }
        while let url = e.nextObject() as? URL {
            let isDir = add(url, try? url.resourceValues(forKeys: Set(keys)))
            if isDir, CrawlRules.shouldSkipDescending(url, homeLibrary: homeLibrary) { e.skipDescendants() }
        }
        return out
    }

    // MARK: 項目管理

    static func makeItem(_ path: String, _ isDir: Bool, _ size: Int64, _ mod: Double) -> CatalogItem {
        let name = (path as NSString).lastPathComponent
        let norm = TextNormalizer.normalize(name)
        return CatalogItem(path: path, norm: norm, isDirectory: isDir, size: size, modified: mod,
                           mask: Self.mask(norm), parent: -1)
    }

    private func makeItem(path: String, isDirectory: Bool, size: Int64, modified: Double) -> CatalogItem {
        Self.makeItem(path, isDirectory, size, modified)
    }

    nonisolated static func mask(_ s: String) -> UInt64 {
        var m: UInt64 = 0
        for u in s.unicodeScalars { m |= 1 << UInt64(u.value % 64) }
        return m
    }

    /// 回傳這次寫入是否真的改變了目錄(新項目,或大小/修改時間不同);只有改變才需要之後存檔
    @discardableResult
    private func insert(_ raw: CatalogItem) -> Bool {
        let old = items[raw.path]
        let changed = old == nil || old!.size != raw.size || old!.modified != raw.modified || old!.isDirectory != raw.isDirectory
        let parentPath = (raw.path as NSString).deletingLastPathComponent
        let pid = parentID(parentPath)
        items[raw.path] = CatalogItem(path: raw.path, norm: raw.norm, isDirectory: raw.isDirectory, size: raw.size,
                                      modified: raw.modified, mask: raw.mask, parent: pid)
        children[parentPath, default: []].insert(raw.path)
        return changed
    }

    private func parentID(_ parentPath: String) -> Int32 {
        if let id = dirIDs[parentPath] { return id }
        let id = Int32(dirNorms.count)
        dirNorms.append(items[parentPath]?.norm ?? TextNormalizer.normalize((parentPath as NSString).lastPathComponent))
        dirIDs[parentPath] = id
        return id
    }

    @discardableResult
    private func remove(subtree path: String) -> Bool {
        guard let item = items.removeValue(forKey: path) else { return false }
        vectors.removeValue(forKey: path)
        children[(path as NSString).deletingLastPathComponent]?.remove(path)
        if item.isDirectory, let kids = children.removeValue(forKey: path) {
            for k in kids { remove(subtree: k) }
        }
        return true
    }

    // MARK: 監看與增量更新

    private func startWatching(since: UInt64) {
        watcher = FSEventsWatcher(paths: roots.map(\.path), since: since) { [weak self] events, _ in
            guard let self else { return }
            Task { await self.enqueue(events.map { $0.path }) }
        }
    }

    private func enqueue(_ paths: [String]) {
        pendingRefresh.formUnion(paths)
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)  // 合併短時間內的大量事件(拉長以減少喚醒)
            await self.flushRefresh()
        }
    }

    private func flushRefresh() async {
        refreshScheduled = false
        let dirs = pendingRefresh
        pendingRefresh = []
        var changed = false
        for d in dirs { if await refresh(dir: d) { changed = true } }
        if changed { markDirty(); onChange?() }
    }

    /// 重新讀一個資料夾(非遞迴),與目錄比對後新增/刪除;新出現的子資料夾會遞迴爬取。
    @discardableResult
    func refresh(dir rawDir: String) async -> Bool {
        let dir = canonicalPath(rawDir)
        let url = URL(fileURLWithPath: dir)
        // 在不屬於任何根目錄、或在被排除的位置底下就忽略
        guard roots.contains(where: { dir == $0.path || dir.hasPrefix($0.path + "/") }),
              !dir.hasPrefix(homeLibrary),
              !dir.split(separator: "/").contains(where: { CrawlRules.skipDirs.contains(String($0)) }) else { return false }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            return remove(subtree: dir)
        }
        var changed = false
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        let current = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                                    options: [.skipsHiddenFiles])) ?? []
        var seen = Set<String>()
        for u in current {
            let v = try? u.resourceValues(forKeys: Set(keys))
            let isD = (v?.isDirectory ?? false) && !(v?.isPackage ?? false)
            seen.insert(u.path)
            let known = items[u.path] != nil
            if insert(makeItem(path: u.path, isDirectory: isD, size: Int64(v?.fileSize ?? 0),
                               modified: v?.contentModificationDate?.timeIntervalSince1970 ?? 0)) { changed = true }
            if isD, !known {
                let batch = await Self.crawl(u, homeLibrary: homeLibrary)
                for i in batch { insert(i) }
                changed = true
            }
        }
        for gone in (children[dir] ?? []).subtracting(seen) { if remove(subtree: gone) { changed = true } }
        return changed
    }

    // MARK: 搜尋

    /// scope:只搜尋此路徑底下。dirsOnly/filesOnly 可限制種類。
    public func search(_ query: String, scope: String? = nil, limit: Int = 300) -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = TextNormalizer.normalize(trimmed)
        guard !q.isEmpty else { return [] }
        let qBytes = Array(q.utf8)
        let qMask = Self.mask(q)
        let tokens = trimmed.split(whereSeparator: \.isWhitespace)
            .map { TextNormalizer.normalize(String($0)) }.filter { !$0.isEmpty }
        let tokenBytes = tokens.count > 1 ? tokens.map { Array($0.utf8) } : []
        let scopePrefix = scope.map { canonicalPath($0) + "/" }

        // 語意分數
        var semantic: [String: Double] = [:]
        if let embedder, !vectors.isEmpty, let qv = embedder.embed(TextNormalizer.semanticText(trimmed)) {
            let norm = max(qv.reduce(0) { $0 + $1 * $1 }.squareRoot(), 1e-9)
            for (path, v) in vectors where v.q.count == qv.count {
                if let scopePrefix, !path.hasPrefix(scopePrefix) { continue }
                var dot: Float = 0
                for i in qv.indices { dot += qv[i] * Float(v.q[i]) }
                let cos = Double(dot / norm * v.scale / 127)
                let s = max(0, (cos - 0.6) / 0.4)
                if s > 0.3 { semantic[path] = s }
            }
        }

        var hits: [SearchHit] = []
        var weak: [CatalogItem] = []
        var n = 0
        for item in items.values {
            n += 1
            if n & 0x3FFF == 0, Task.isCancelled { return [] }
            if let scopePrefix, !item.path.hasPrefix(scopePrefix) { continue }
            var lex = 0.0
            if item.norm == q { lex = 1 }
            else if Self.hasPrefix(item.norm, qBytes) { lex = 0.97 }
            else if Self.contains(item.norm, qBytes) { lex = 0.9 }
            else if !tokenBytes.isEmpty, tokenBytes.allSatisfy({ Self.contains(item.norm, $0) }) { lex = 0.85 }
            else if item.parent >= 0, Self.contains(dirNorms[Int(item.parent)], qBytes) { lex = 0.6 }
            else if item.mask & qMask == qMask { weak.append(item) }

            let sem = semantic[item.path]
            let score = min(1, max(lex, 0.9 * (sem ?? 0)) + 0.05 * min(lex, sem ?? 0))
            if score >= (lex > 0 ? 0.3 : 0.45) { hits.append(SearchHit(item: item, score: score, lexical: lex, semantic: sem)) }
        }

        // 精確結果太少時才做較貴的容錯比對(依序出現/打錯字)
        if hits.count < 30 {
            for item in weak {
                let lex = Self.fuzzy(q, item.norm)
                if lex >= 0.35 { hits.append(SearchHit(item: item, score: lex, lexical: lex, semantic: semantic[item.path])) }
            }
        }
        // 只靠語意、沒有字面關係的項目已在上面的迴圈處理(score 來自 sem)

        hits.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.item.modified > $1.item.modified
        }
        return Array(hits.prefix(limit))
    }

    static func fuzzy(_ q: String, _ t: String) -> Double {
        var best = 0.0
        // 依序出現:涵蓋範圍不能比查詢長太多,否則只是長檔名裡剛好湊到字母
        if q.count >= 3, let span = LexicalMatcher.subsequenceSpan(Array(q), in: Array(t)), span <= q.count + max(2, q.count / 2) {
            best = 0.4 + 0.3 * Double(q.count) / Double(span)
        }
        // 打錯字:至少 4 個字,且字元組合相似度夠高
        if q.count >= 4, abs(q.count - t.count) <= max(4, q.count) {
            let d = LexicalMatcher.diceBigram(q, t)
            if d >= 0.6 { best = max(best, 0.5 * d) }
        }
        return best
    }

    private static func contains(_ hay: String, _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return false }
        var h = hay
        return h.withUTF8 { hp in
            needle.withUnsafeBufferPointer { np in
                memmem(hp.baseAddress, hp.count, np.baseAddress, np.count) != nil
            }
        }
    }

    private static func hasPrefix(_ hay: String, _ needle: [UInt8]) -> Bool {
        var h = hay
        return h.withUTF8 { hp in
            hp.count >= needle.count && needle.withUnsafeBufferPointer { memcmp(hp.baseAddress, $0.baseAddress, needle.count) == 0 }
        }
    }

    // MARK: 語意索引

    private static let skipSemanticExt: Set<String> = ["swift", "json", "js", "ts", "map", "o", "a", "dylib", "plist", "strings",
                                                       "pyc", "class", "xml", "lock", "log", "tmp", "dat", "db", "sqlite", "cache"]

    private func beginEmbedding() {
        embedTask?.cancel()
        embedTask = Task(priority: .background) { await self.buildEmbeddings() }
    }

    /// 目前是否在用電池
    private nonisolated static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeRetainedValue() as String? else { return false }
        return type == "Battery Power"
    }

    /// 語意索引是最耗電的背景工作:低耗電模式下不做;用電池時只做最近的一小部分;機器過熱就停。
    private func buildEmbeddings() async {
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        let cap = Self.onBattery ? 10_000 : 40_000
        guard let factory = embedderFactory else { return }
        if embedder == nil {
            let sample = Array(items.values.prefix(2000)).map { ($0.path as NSString).deletingPathExtension.components(separatedBy: "/").last ?? "" }
            embedder = factory(sample)
        }
        guard let embedder else { return }
        loadVectorCache(embedder: embedder)

        // 優先處理最近修改的項目;略過程式碼/資料類副檔名與純數字檔名
        let candidates = items.values
            .filter { !Self.skipSemanticExt.contains(($0.path as NSString).pathExtension.lowercased()) && vectors[$0.path] == nil }
            .sorted { $0.modified > $1.modified }
            .prefix(max(0, cap - vectors.count))
        let list = Array(candidates)
        var done = 0
        for chunk in stride(from: 0, to: list.count, by: 25) {
            if Task.isCancelled { return }
            for item in list[chunk..<min(chunk + 25, list.count)] {
                let url = item.path as NSString
                let text = TextNormalizer.semanticText(
                    (url.deletingLastPathComponent as NSString).lastPathComponent + " " + (url.lastPathComponent as NSString).deletingPathExtension)
                if text.contains(where: \.isLetter), let v = embedder.embed(text) { vectors[item.path] = Self.quantize(v) }
            }
            done = min(chunk + 25, list.count)
            if done % 500 == 0 || done == list.count { phase = .embedding(done: done, total: list.count) }
            if done % 10_000 == 0 { saveVectorCache(embedder: embedder) }  // 中途關閉也不會全部重算
            // 每批之間休息,讓這項工作只佔一小部分的 CPU;過熱或進入低耗電模式就停下來
            if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
                || ProcessInfo.processInfo.isLowPowerModeEnabled { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        phase = .ready(files: items.count)
        saveVectorCache(embedder: embedder)
        onChange?()
    }

    private static func quantize(_ v: [Float]) -> QuantVec {
        let norm = max(v.reduce(0) { $0 + $1 * $1 }.squareRoot(), 1e-9)
        let unit = v.map { $0 / norm }
        let scale = max(unit.map(abs).max() ?? 1, 1e-9)
        return QuantVec(scale: scale, q: unit.map { Int8(max(-127, min(127, ($0 / scale * 127).rounded()))) })
    }

    // MARK: 快取讀寫

    private var catalogURL: URL { cacheDir.appendingPathComponent("catalog.plist") }
    private var vectorsURL: URL { cacheDir.appendingPathComponent("vectors.plist") }

    // MARK: 存檔(延後、合併、在背景最低優先權執行)

    private var dirty = false
    private var saveScheduled = false

    /// 目錄有變動:排程在一段時間後存檔,期間的變動都合併成一次。
    /// 快取過期是安全的:快取裡記了檔案系統事件的進度(eventID),下次開啟會補上漏掉的變動。
    private func markDirty() {
        dirty = true
        guard !saveScheduled else { return }
        saveScheduled = true
        Task(priority: .utility) {
            try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)  // 最多每 5 分鐘存一次
            await self.saveIfDirty()
        }
    }

    private func saveIfDirty() async {
        saveScheduled = false
        guard dirty else { return }
        await saveCacheNow()
    }

    /// 在 actor 上只複製欄位(很快),編碼與寫檔交給背景執行緒,不佔住搜尋與更新
    private func saveCacheNow() async {
        dirty = false
        let all = Array(items.values)
        var bits = Data(count: (all.count + 7) / 8)
        for (i, it) in all.enumerated() where it.isDirectory { bits[i / 8] |= 1 << UInt8(i % 8) }
        let cache = CatalogCache(roots: roots.map(\.path), eventID: watcher?.latestID ?? 0, paths: all.map(\.path), norms: all.map(\.norm),
                                 sizes: all.map(\.size), mods: all.map(\.modified), dirs: bits)
        let url = catalogURL
        await Task.detached(priority: .background) {
            let enc = PropertyListEncoder(); enc.outputFormat = .binary
            if let data = try? enc.encode(cache) { try? data.write(to: url, options: .atomic) }
        }.value
    }

    private func loadCache() -> CatalogCache? {
        guard let data = try? Data(contentsOf: catalogURL) else { return nil }
        return try? PropertyListDecoder().decode(CatalogCache.self, from: data)
    }

    private func saveVectorCache(embedder: TextEmbedder) {
        guard let dim = vectors.values.first?.q.count else { return }
        let entries = Array(vectors)
        var blob = Data(capacity: entries.count * dim)
        for (_, v) in entries { blob.append(contentsOf: v.q.map { UInt8(bitPattern: $0) }) }
        let cache = VectorCache(embedder: embedder.name, dim: dim, paths: entries.map(\.key),
                                scales: entries.map(\.value.scale), blob: blob)
        let enc = PropertyListEncoder(); enc.outputFormat = .binary
        if let data = try? enc.encode(cache) { try? data.write(to: vectorsURL, options: .atomic) }
    }

    private func loadVectorCache(embedder: TextEmbedder) {
        guard vectors.isEmpty, let data = try? Data(contentsOf: vectorsURL),
              let c = try? PropertyListDecoder().decode(VectorCache.self, from: data),
              c.embedder == embedder.name, c.blob.count == c.paths.count * c.dim else { return }
        for (i, p) in c.paths.enumerated() where items[p] != nil {
            let slice = c.blob[(i * c.dim)..<((i + 1) * c.dim)]
            vectors[p] = QuantVec(scale: c.scales[i], q: slice.map { Int8(bitPattern: $0) })
        }
    }
}

// MARK: - 給整理工具使用的快照

extension FileCatalog {
    /// 目錄中某範圍底下的所有「檔案」(不含資料夾),不必重新掃描磁碟。
    public func snapshot(scope: String?, minSize: Int64 = 0) -> [FileEntry] {
        let prefix = scope.map { canonicalPath($0) + "/" }
        return itemsView.compactMap { i in
            guard !i.isDirectory, i.size >= minSize else { return nil }
            if let prefix, !i.path.hasPrefix(prefix) { return nil }
            return FileEntry(url: URL(fileURLWithPath: i.path), size: i.size, created: nil,
                             modified: Date(timeIntervalSince1970: i.modified))
        }
    }
}
