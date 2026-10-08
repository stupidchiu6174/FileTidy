import Foundation
import FileTidyCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 用 Apple 的「裝置端」語言模型,把統計資料寫成一段比較像人話的說明。
/// 完全在這台 Mac 上執行,不連網、不上傳任何檔名;這台 Mac 沒有開啟 Apple Intelligence 時會回報「無法使用」。
enum AISummarizer {
    enum Result {
        case text(String)
        case unavailable(String)
    }

    static func summarize(_ a: FolderAnalysis) async -> Result {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available: break
            case .unavailable(let reason):
                return .unavailable(String(localized: "這台 Mac 目前無法使用裝置端 AI(\(String(describing: reason)))"))
            @unknown default:
                return .unavailable(String(localized: "這台 Mac 目前無法使用裝置端 AI"))
            }
            do {
                let session = LanguageModelSession(instructions: """
                    You are a careful file-organization assistant. You are given statistics about one folder. \
                    Explain in 3 to 5 short sentences what this folder seems to contain, what it is probably used for, \
                    and anything worth noticing (very large files, many empty files, cache or dependency folders, old unused content). \
                    Only mention file or folder names that appear in the data. Do not invent contents. \
                    Reply in \(languageName).
                    """)
                let response = try await session.respond(to: facts(a))
                return .text(response.content.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                return .unavailable(String(localized: "AI 摘要失敗:\(error.localizedDescription)"))
            }
        }
        #endif
        return .unavailable(String(localized: "需要 macOS 26 以上並開啟 Apple Intelligence 才能使用裝置端 AI 摘要"))
    }

    /// 目前介面語言的名稱,用來指示模型用哪種語言回答
    static var languageName: String {
        switch Bundle.main.preferredLocalizations.first ?? "en" {
        case let l where l.hasPrefix("ja"): "日本語 (Japanese)"
        case let l where l.hasPrefix("zh"): "繁體中文 (Traditional Chinese)"
        default: "English"
        }
    }

    /// 只給模型統計與名稱,不給檔案內容
    private static func facts(_ a: FolderAnalysis) -> String {
        var lines: [String] = []
        lines.append("Folder name: \(a.folderName)")
        lines.append("Files: \(a.fileCount), folders: \(a.folderCount), total size: \(formatBytes(a.totalBytes)), max depth: \(a.maxDepth)")
        if a.emptyFileCount > 0 { lines.append("Empty (0-byte) files: \(a.emptyFileCount)") }
        if let o = a.oldest, let n = a.newest { lines.append("Modified between \(o.formatted(date: .numeric, time: .omitted)) and \(n.formatted(date: .numeric, time: .omitted))") }
        let cats = a.categories.prefix(6).map { c -> String in
            let title = FileCategory(rawValue: c.id)?.rawValue ?? c.id
            return "\(title): \(c.count) files, \(formatBytes(c.bytes))"
        }
        if !cats.isEmpty { lines.append("File types: " + cats.joined(separator: "; ")) }
        let exts = a.extensions.prefix(8).map { ".\($0.ext.isEmpty ? "(none)" : $0.ext) ×\($0.count)" }
        if !exts.isEmpty { lines.append("Top extensions: " + exts.joined(separator: ", ")) }
        if !a.projects.isEmpty { lines.append("Detected project markers: " + a.projects.joined(separator: ", ")) }
        if !a.skippedDirs.isEmpty { lines.append("Dependency/cache folders not scanned: " + a.skippedDirs.joined(separator: ", ")) }
        let kids = a.children.prefix(8).map { "\($0.name) (\($0.isDirectory ? "folder" : "file"), \(formatBytes($0.bytes)))" }
        if !kids.isEmpty { lines.append("Largest items at top level: " + kids.joined(separator: "; ")) }
        let big = a.largest.prefix(5).map { "\(($0.relativePath as NSString).lastPathComponent) (\(formatBytes($0.size)))" }
        if !big.isEmpty { lines.append("Largest files: " + big.joined(separator: "; ")) }
        let rec = a.recent.prefix(5).map { ($0.relativePath as NSString).lastPathComponent }
        if !rec.isEmpty { lines.append("Most recently modified: " + rec.joined(separator: ", ")) }
        if a.truncated { lines.append("Note: the folder is very large; only part of it was analyzed.") }
        return lines.joined(separator: "\n")
    }
}
