import Foundation

public struct RenameRules: Equatable, Sendable {
    public enum SpaceMode: String, CaseIterable, Sendable {
        case keep, underscore, hyphen, remove
        public var title: String {
            switch self {
            case .keep: String(localized: "保留空格")
            case .underscore: String(localized: "換成底線")
            case .hyphen: String(localized: "換成連字號")
            case .remove: String(localized: "移除")
            }
        }
    }
    public enum CaseMode: String, CaseIterable, Sendable {
        case keep, lower, upper
        public var title: String {
            switch self {
            case .keep: String(localized: "不變")
            case .lower: String(localized: "全小寫")
            case .upper: String(localized: "全大寫")
            }
        }
    }

    public var find = ""
    public var replace = ""
    public var spaces: SpaceMode = .keep
    public var caseMode: CaseMode = .keep
    public var prefix = ""
    public var suffix = ""
    public var insertDate = false
    public var numbering = false
    public var startNumber = 1
    public var digits = 3

    public init() {}
    public var isIdentity: Bool { self == RenameRules() }
}

public enum Renamer {
    public static func plan(entries: [FileEntry], rules: RenameRules) -> OperationPlan {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        var actions: [PlannedAction] = []
        var taken = Set(entries.map { $0.url.standardizedFileURL.path })
        var counter = rules.startNumber

        for entry in entries.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            var stem = entry.stem
            if !rules.find.isEmpty { stem = stem.replacingOccurrences(of: rules.find, with: rules.replace) }
            switch rules.spaces {
            case .keep: break
            case .underscore: stem = stem.replacingOccurrences(of: " ", with: "_")
            case .hyphen: stem = stem.replacingOccurrences(of: " ", with: "-")
            case .remove: stem = stem.replacingOccurrences(of: " ", with: "")
            }
            switch rules.caseMode {
            case .keep: break
            case .lower: stem = stem.lowercased()
            case .upper: stem = stem.uppercased()
            }
            if rules.insertDate { stem = fmt.string(from: entry.bestDate) + " " + stem }
            stem = rules.prefix + stem + rules.suffix
            if rules.numbering {
                stem += " " + String(format: "%0\(rules.digits)d", counter)
                counter += 1
            }
            stem = stem.trimmingCharacters(in: .whitespaces)
            guard !stem.isEmpty else { continue }

            let newName = entry.ext.isEmpty ? stem : stem + "." + entry.url.pathExtension
            guard newName != entry.name else { continue }
            var dest = entry.url.deletingLastPathComponent().appendingPathComponent(newName)
            var note = ""
            if taken.contains(dest.standardizedFileURL.path) {
                dest = Executor.uniqueURL(dest)
                note = String(localized: "名稱衝突,已自動加上序號")
            }
            taken.insert(dest.standardizedFileURL.path)
            actions.append(PlannedAction(kind: .move, source: entry.url, destination: dest, note: note))
        }
        return OperationPlan(title: String(localized: "批次改名"), actions: actions)
    }
}
