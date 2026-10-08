import Foundation

public struct JournalEntry: Codable, Identifiable, Sendable {
    public struct Move: Codable, Sendable { public let from: String; public let to: String }
    public struct Trashed: Codable, Sendable { public let original: String; public let trash: String }

    public let id: UUID
    public let date: Date
    public let title: String
    public var moves: [Move]
    public var trashed: [Trashed]
    public var createdDirs: [String]
    public var copies: [String]? = nil
    public var undone: Bool

    public var count: Int { moves.count + trashed.count + (copies?.count ?? 0) }
    var isEmpty: Bool { count == 0 && createdDirs.isEmpty }
}

/// 把每次套用的結果存成 JSON,供復原使用。
public final class Journal {
    public private(set) var entries: [JournalEntry] = []
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FileTidy", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.fileURL = base.appendingPathComponent("journal.json")
        }
        if let data = try? Data(contentsOf: self.fileURL),
           let decoded = try? JSONDecoder.iso.decode([JournalEntry].self, from: data) {
            entries = decoded
        }
    }

    func append(_ entry: JournalEntry) {
        entries.insert(entry, at: 0)
        save()
    }

    /// 記錄「由 FileTidy 建立的新檔案」(壓縮檔、替身),復原時會把它們移到垃圾桶。
    public func recordCreated(title: String, paths: [String]) {
        guard !paths.isEmpty else { return }
        append(JournalEntry(id: UUID(), date: Date(), title: title, moves: [], trashed: [],
                            createdDirs: [], copies: paths, undone: false))
    }

    func markUndone(_ id: UUID) {
        if let i = entries.firstIndex(where: { $0.id == id }) { entries[i].undone = true }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder.iso.encode(entries) { try? data.write(to: fileURL, options: .atomic) }
    }
}

private extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
private extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

/// 目標位置已有同名項目時的處理方式
public enum ConflictResolution: Sendable {
    case keepBoth   // 新的自動改名(加序號)
    case replace    // 舊的移到垃圾桶(可復原),新的使用原名
    case skip       // 這一項不處理
}

public struct ExecutionResult: Sendable {
    public let applied: Int
    public let failures: [String]
}

public enum Executor {
    /// 只會「移動」與「丟垃圾桶」,絕不直接刪除檔案。
    public static func apply(_ plan: OperationPlan, selected: Set<UUID>,
                             resolutions: [UUID: ConflictResolution] = [:], journal: Journal) -> ExecutionResult {
        let fm = FileManager.default
        var moves: [JournalEntry.Move] = []
        var trashed: [JournalEntry.Trashed] = []
        var created: [String] = []
        var copied: [String] = []
        var failures: [String] = []

        for action in plan.actions where selected.contains(action.id) {
            switch action.kind {
            case .move:
                guard let destination = action.destination else { continue }
                do {
                    try createDirectories(destination.deletingLastPathComponent(), created: &created)
                    guard let final = try resolveDestination(action, resolutions[action.id] ?? .keepBoth, trashed: &trashed) else { continue }
                    if isCaseOnlyRename(action.source, final) {
                        // 大小寫不分的磁碟上,只改大小寫要經過暫時名稱
                        let tmp = final.deletingLastPathComponent().appendingPathComponent(".tidy-\(UUID().uuidString)")
                        try fm.moveItem(at: action.source, to: tmp)
                        try fm.moveItem(at: tmp, to: final)
                    } else {
                        try fm.moveItem(at: action.source, to: final)
                    }
                    moves.append(.init(from: action.source.path, to: final.path))
                } catch {
                    failures.append("\(action.source.lastPathComponent):\(error.localizedDescription)")
                }
            case .copy:
                guard let destination = action.destination else { continue }
                do {
                    try createDirectories(destination.deletingLastPathComponent(), created: &created)
                    guard let final = try resolveDestination(action, resolutions[action.id] ?? .keepBoth, trashed: &trashed) else { continue }
                    try fm.copyItem(at: action.source, to: final)
                    copied.append(final.path)
                } catch {
                    failures.append("\(action.source.lastPathComponent):\(error.localizedDescription)")
                }
            case .mkdir:
                guard let destination = action.destination else { continue }
                do { try createDirectories(uniqueURL(destination), created: &created) }
                catch { failures.append("\(destination.lastPathComponent):\(error.localizedDescription)") }
            case .trash:
                do {
                    var result: NSURL?
                    try fm.trashItem(at: action.source, resultingItemURL: &result)
                    if let path = (result as URL?)?.path {
                        trashed.append(.init(original: action.source.path, trash: path))
                    }
                } catch {
                    failures.append("\(action.source.lastPathComponent):\(error.localizedDescription)")
                }
            }
        }

        let entry = JournalEntry(id: UUID(), date: Date(), title: plan.title, moves: moves,
                                 trashed: trashed, createdDirs: created, copies: copied, undone: false)
        if !entry.isEmpty { journal.append(entry) }
        return ExecutionResult(applied: max(entry.count, entry.createdDirs.isEmpty ? 0 : 1), failures: failures)
    }

    // MARK: 衝突處理

    /// 會與既有項目衝突的動作(目的地已存在,且不是同一個檔案)。
    public static func conflicts(in plan: OperationPlan, selected: Set<UUID>) -> [PlannedAction] {
        plan.actions.filter { a in
            selected.contains(a.id) && (a.kind == .move || a.kind == .copy) && hasConflict(a)
        }
    }

    public static func hasConflict(_ a: PlannedAction) -> Bool {
        guard let dest = a.destination, FileManager.default.fileExists(atPath: dest.path) else { return false }
        return !sameFile(a.source, dest)
    }

    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        if a.standardizedFileURL.path == b.standardizedFileURL.path { return true }
        let ida = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        let idb = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        if let ida, let idb { return ida.isEqual(idb) }
        return false
    }

    /// 同一個檔案、只有大小寫不同(例如 a.txt → A.txt)
    static func isCaseOnlyRename(_ source: URL, _ dest: URL) -> Bool {
        source.path != dest.path && source.path.lowercased() == dest.path.lowercased()
    }

    /// 決定實際目的地。回傳 nil 代表這一項略過。取代時,舊項目先移到垃圾桶並記進紀錄,才能一起復原。
    private static func resolveDestination(_ action: PlannedAction, _ resolution: ConflictResolution,
                                           trashed: inout [JournalEntry.Trashed]) throws -> URL? {
        guard let dest = action.destination else { return nil }
        if dest.standardizedFileURL.path == action.source.standardizedFileURL.path { return nil }  // 沒有變化
        guard hasConflict(action) else { return dest }
        switch resolution {
        case .skip: return nil
        case .keepBoth: return uniqueURL(dest)
        case .replace:
            var result: NSURL?
            try FileManager.default.trashItem(at: dest, resultingItemURL: &result)
            if let path = (result as URL?)?.path { trashed.append(.init(original: dest.path, trash: path)) }
            return dest
        }
    }

    /// 套用整份計畫(給 Finder 式的即時操作用)。
    public static func run(_ plan: OperationPlan, resolutions: [UUID: ConflictResolution] = [:], journal: Journal) -> ExecutionResult {
        apply(plan, selected: Set(plan.actions.map(\.id)), resolutions: resolutions, journal: journal)
    }

    /// ⌘Z:復原最近一次尚未復原的操作。
    @discardableResult
    public static func undoLatest(journal: Journal) -> (JournalEntry, [String])? {
        guard let e = journal.entries.first(where: { !$0.undone }) else { return nil }
        return (e, undo(e, journal: journal))
    }

    public static func undo(_ entry: JournalEntry, journal: Journal) -> [String] {
        let fm = FileManager.default
        var failures: [String] = []

        func restore(from: String, to: String) {
            let source = URL(fileURLWithPath: from), target = URL(fileURLWithPath: to)
            guard fm.fileExists(atPath: from) else { failures.append(String(localized: "找不到 \(source.lastPathComponent)"));return }
            guard !fm.fileExists(atPath: to) else { failures.append(String(localized: "原位置已有同名檔案:\(target.lastPathComponent)"));return }
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: source, to: target)
            } catch {
                failures.append("\(target.lastPathComponent):\(error.localizedDescription)")
            }
        }

        for c in (entry.copies ?? []).reversed() {
            do { try fm.trashItem(at: URL(fileURLWithPath: c), resultingItemURL: nil) }
            catch { failures.append("\(URL(fileURLWithPath: c).lastPathComponent):\(error.localizedDescription)") }
        }
        for m in entry.moves.reversed() { restore(from: m.to, to: m.from) }
        for t in entry.trashed { restore(from: t.trash, to: t.original) }

        for dir in entry.createdDirs.reversed() {
            let url = URL(fileURLWithPath: dir)
            let contents = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            if contents.allSatisfy({ $0 == ".DS_Store" }) { try? fm.removeItem(at: url) }
        }

        if failures.isEmpty { journal.markUndone(entry.id) }
        return failures
    }

    private static func createDirectories(_ dir: URL, created: inout [String]) throws {
        let fm = FileManager.default
        var missing: [URL] = []
        var current = dir
        while !fm.fileExists(atPath: current.path), current.path != "/" {
            missing.append(current)
            current.deleteLastPathComponent()
        }
        for url in missing.reversed() {
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            created.append(url.path)
        }
    }

    public static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
