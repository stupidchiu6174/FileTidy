import XCTest
@testable import FileTidyCore

/// 只在設定 FILETIDY_BENCH=1 時執行:用真實家目錄量測索引規模與搜尋速度。
final class BenchTests: XCTestCase {
    func testRealHomeCatalog() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FILETIDY_BENCH"] != nil)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString)")
        let cat = FileCatalog(roots: CrawlRules.defaultRoots(), cacheDir: cache)
        let t0 = Date()
        await cat.start(semantic: { _ in nil })
        let crawl = Date().timeIntervalSince(t0)
        let n = await cat.count
        print("BENCH roots", await cat.roots.map(\.path))
        print("BENCH crawl \(String(format: "%.1f", crawl))s items=\(n)")
        for q in ["pdf", "report", "my photo", "屏", "invoce", "zzzzqq"] {
            let t = Date()
            let r = await cat.search(q)
            print("BENCH search '\(q)' \(String(format: "%.0f", Date().timeIntervalSince(t) * 1000))ms hits=\(r.count) top=\(r.first?.item.name ?? "-")")
        }
        let t1 = Date()
        let c2 = FileCatalog(roots: CrawlRules.defaultRoots(), cacheDir: cache)
        await c2.start(semantic: { _ in nil })
        print("BENCH cache-load \(String(format: "%.1f", Date().timeIntervalSince(t1)))s items=\(await c2.count)")
        let size = (try? FileManager.default.attributesOfItem(atPath: cache.appendingPathComponent("catalog.plist").path)[.size] as? Int) ?? 0
        print("BENCH cache-size \(size / 1_000_000)MB")
    }
}
