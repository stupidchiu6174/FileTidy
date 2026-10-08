import Foundation
import CryptoKit

public struct DuplicateGroup: Identifiable, Sendable {
    public let id = UUID()
    public let files: [FileEntry]
    public var size: Int64 { files.first?.size ?? 0 }
    public var wastedBytes: Int64 { size * Int64(max(files.count - 1, 0)) }
}

public enum DuplicateFinder {
    /// 先比大小,再比前 64KB 雜湊,最後比完整 SHA-256,避免對每個檔案都整檔讀取。
    public static func find(_ entries: [FileEntry], progress: ((Int, Int) -> Void)? = nil) -> [DuplicateGroup] {
        let candidates = Dictionary(grouping: entries.filter { $0.size > 0 }, by: \.size).values.filter { $0.count > 1 }
        let total = candidates.reduce(0) { $0 + $1.count }
        var done = 0
        var groups: [DuplicateGroup] = []

        for sameSize in candidates {
            var byPartial: [String: [FileEntry]] = [:]
            for e in sameSize {
                if let h = hash(e.url, limit: 64 * 1024) { byPartial[h, default: []].append(e) }
                done += 1; progress?(done, total * 2)
            }
            for partial in byPartial.values where partial.count > 1 {
                var byFull: [String: [FileEntry]] = [:]
                for e in partial {
                    if let h = hash(e.url, limit: nil) { byFull[h, default: []].append(e) }
                    done += 1; progress?(min(done, total * 2), total * 2)
                }
                for same in byFull.values where same.count > 1 {
                    groups.append(DuplicateGroup(files: same.sorted { $0.bestDate < $1.bestDate }))
                }
            }
        }
        return groups.sorted { $0.wastedBytes > $1.wastedBytes }
    }

    /// 每組保留最舊的一份,其餘丟垃圾桶。
    public static func plan(_ groups: [DuplicateGroup]) -> OperationPlan {
        var actions: [PlannedAction] = []
        for g in groups {
            guard let keep = g.files.first else { continue }
            for dup in g.files.dropFirst() {
                actions.append(PlannedAction(kind: .trash, source: dup.url, note: String(localized: "與 \(keep.name) 相同")))
            }
        }
        return OperationPlan(title: String(localized: "清除重複檔案"), actions: actions)
    }

    private static func hash(_ url: URL, limit: Int?) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = limit ?? Int.max
        while remaining > 0 {
            let chunk = min(1 << 20, remaining)
            guard let data = try? handle.read(upToCount: chunk), !data.isEmpty else { break }
            hasher.update(data: data)
            remaining -= data.count
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
