import AppKit
import FileTidyCore

extension AppModel {
    /// 目的地已有同名項目時詢問使用者(取代 / 兩者都保留 / 跳過 / 停止)。
    /// 回傳 nil 代表「停止」,整批都不執行。
    func resolveConflicts(_ plan: OperationPlan, selected: Set<UUID>) -> [UUID: ConflictResolution]? {
        let conflicts = Executor.conflicts(in: plan, selected: selected)
        guard !conflicts.isEmpty else { return [:] }
        var result: [UUID: ConflictResolution] = [:]
        var applyToAll: ConflictResolution?

        for (i, action) in conflicts.enumerated() {
            if let all = applyToAll { result[action.id] = all; continue }
            guard let dest = action.destination else { continue }
            let remaining = conflicts.count - i - 1

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "「\(dest.lastPathComponent)」已存在於這個位置")
            alert.informativeText = String(localized: "要取代它嗎?被取代的項目會移到垃圾桶,可以用 ⌘Z 復原。\n\n現有:\(describe(dest))\n新的:\(describe(action.source))")
            alert.addButton(withTitle: String(localized: "取代"))
            alert.addButton(withTitle: String(localized: "兩者都保留"))
            if conflicts.count > 1 { alert.addButton(withTitle: String(localized: "跳過")) }
            alert.addButton(withTitle: String(localized: "停止"))

            var applyAllBox: NSButton?
            if remaining > 0 {
                let box = NSButton(checkboxWithTitle: String(localized: "對其餘 \(remaining) 個衝突都這樣處理"), target: nil, action: nil)
                alert.accessoryView = box
                applyAllBox = box
            }

            let choice: ConflictResolution?
            switch alert.runModal() {
            case .alertFirstButtonReturn: choice = .replace
            case .alertSecondButtonReturn: choice = .keepBoth
            case .alertThirdButtonReturn where conflicts.count > 1: choice = .skip
            default: choice = nil  // 停止
            }
            guard let choice else { return nil }
            result[action.id] = choice
            if applyAllBox?.state == .on { applyToAll = choice }
        }
        return result
    }

    private func describe(_ url: URL) -> String {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
        let date = v?.contentModificationDate?.formatted(date: .abbreviated, time: .shortened) ?? "—"
        let size = (v?.isDirectory ?? false) ? String(localized: "資料夾") : formatBytes(Int64(v?.fileSize ?? 0))
        return String(localized: "\(size),修改於 \(date)")
    }
}
