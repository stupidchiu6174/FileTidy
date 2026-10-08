import Foundation
import CryptoKit

/// 把每個資料夾的分析結果存在本機,讓右鍵選單能知道「這個資料夾已經分析過了」。
public final class AnalysisStore: @unchecked Sendable {
    public static let shared = AnalysisStore()

    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FileTidy/analyses", isDirectory: true)
        self.directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    private func fileURL(for path: String) -> URL {
        let digest = SHA256.hash(data: Data(canonicalPath(path).utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(String(digest.prefix(40)) + ".json")
    }

    public func load(_ path: String) -> FolderAnalysis? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL(for: path)) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(FolderAnalysis.self, from: data)
    }

    public func exists(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return FileManager.default.fileExists(atPath: fileURL(for: path).path)
    }

    public func save(_ analysis: FolderAnalysis) {
        lock.lock(); defer { lock.unlock() }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(analysis) { try? data.write(to: fileURL(for: analysis.path), options: .atomic) }
    }

    public func delete(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL(for: path))
    }
}
