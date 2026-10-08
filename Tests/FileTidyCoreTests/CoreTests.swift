import XCTest
@testable import FileTidyCore

final class CoreTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tidy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    func make(_ name: String, _ content: String = "x") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    func journal() -> Journal { Journal(fileURL: dir.appendingPathComponent(".journal.json")) }

    // MARK: 搜尋正規化
    func testNormalizeIgnoresSpacesPunctuationCaseWidth() {
        XCTAssertEqual(TextNormalizer.normalize("My  Photo-01"), "myphoto01")
        XCTAssertEqual(TextNormalizer.normalize("my_photo01"), "myphoto01")
        XCTAssertEqual(TextNormalizer.normalize("ＭＹ　ＰＨＯＴＯ０１"), "myphoto01")
        XCTAssertEqual(TextNormalizer.normalize("Café"), "cafe")
    }
    func testTraditionalSimplifiedEquivalent() {
        XCTAssertEqual(TextNormalizer.normalize("資料管理"), TextNormalizer.normalize("资料管理"))
    }
    func testLexicalScoring() {
        XCTAssertGreaterThan(LexicalMatcher.score(query: "my photo", target: "my_photo_01"), 0.85)
        XCTAssertGreaterThan(LexicalMatcher.score(query: "photo my", target: "my_photo_01"), 0.8)   // 順序顛倒
        XCTAssertGreaterThan(LexicalMatcher.score(query: "報 告 2024", target: "年度報告2024"), 0.85)  // 中文夾空格
        XCTAssertGreaterThan(LexicalMatcher.score(query: "mphoto", target: "my_photo"), 0.4)          // 依序出現
        XCTAssertGreaterThan(LexicalMatcher.score(query: "invoce", target: "invoice"), 0.3)            // 打錯字
        XCTAssertEqual(LexicalMatcher.score(query: "zzz", target: "invoice"), 0)
    }
    func testCatalogSearchAndIncrementalUpdate() async throws {
        try make("My Photo 01.jpg"); try make("budget.xlsx"); try make("旅行/IMG_2031.heic")
        try make("node_modules/pkg/hidden.js"); try make(".secret/x.txt")
        let cat = FileCatalog(roots: [dir], cacheDir: dir.appendingPathComponent(".cache"))
        await cat.start(semantic: { _ in nil })

        let r1 = await cat.search("myphoto")
        XCTAssertEqual(r1.first?.item.name, "My Photo 01.jpg")
        let r2 = await cat.search("旅 行")
        XCTAssertTrue(r2.contains { $0.item.name == "IMG_2031.heic" }, "應靠所在資料夾名稱找到")
        let r3 = await cat.search("photo my")
        XCTAssertEqual(r3.first?.item.name, "My Photo 01.jpg")
        let r4 = await cat.search("invoce")                       // 打錯字,先不會有這個檔
        XCTAssertTrue(r4.isEmpty)
        let none = await cat.search("hidden")
        XCTAssertTrue(none.isEmpty, "node_modules 內容不應被索引")
        let none2 = await cat.search("secret")
        XCTAssertTrue(none2.filter { $0.item.name == "x.txt" }.isEmpty, "隱藏資料夾不應被索引")

        // 增量更新:新增、刪除
        try make("invoice 2024.pdf")
        await cat.refresh(dir: dir.path)
        let r5 = await cat.search("invoce")
        XCTAssertEqual(r5.first?.item.name, "invoice 2024.pdf")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("budget.xlsx"))
        await cat.refresh(dir: dir.path)
        let r6 = await cat.search("budget")
        XCTAssertTrue(r6.isEmpty)

        // 範圍搜尋
        let scoped = await cat.search("img", scope: dir.appendingPathComponent("旅行").path)
        XCTAssertEqual(scoped.count, 1)
    }
    func testCatalogCacheReload() async throws {
        try make("alpha report.docx")
        let cache = dir.appendingPathComponent(".cache")
        let c1 = FileCatalog(roots: [dir], cacheDir: cache)
        await c1.start(semantic: { _ in nil })
        let c2 = FileCatalog(roots: [dir], cacheDir: cache)
        await c2.start(semantic: { _ in nil })
        let r = await c2.search("alphareport")
        XCTAssertEqual(r.first?.item.name, "alpha report.docx")
    }
    func testFinderOpsAreUndoable() throws {
        let f = try make("a.txt", "hello")
        let j = journal()
        _ = Executor.run(FileOps.newFolder(in: dir, name: "新資料夾"), journal: j)
        let folder = dir.appendingPathComponent("新資料夾")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        _ = Executor.run(FileOps.copy([f], into: folder), journal: j)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.txt").path))
        _ = Executor.run(FileOps.rename(f, to: "b.txt"), journal: j)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("b.txt").path))
        _ = Executor.run(FileOps.duplicate([dir.appendingPathComponent("b.txt")]), journal: j)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("b 副本.txt").path))
        // 不能把資料夾複製進自己
        XCTAssertTrue(FileOps.copy([folder], into: folder).actions.isEmpty)

        while Executor.undoLatest(journal: j) != nil {}   // 連續 ⌘Z 全部還原
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("b 副本.txt").path))
    }
    func testDirectoryLister() throws {
        try make("x.txt"); try make("sub/y.txt"); try make(".hidden")
        XCTAssertEqual(try DirectoryLister.list(dir, showHidden: false).count, 2)
        XCTAssertGreaterThan(try DirectoryLister.list(dir, showHidden: true).count, 2)
    }
    func testNLEmbedderIfAvailable() throws {
        guard let e = NLSentenceEmbedder.make(forSamples: ["travel photos", "tax report"]) else {
            throw XCTSkip("此環境沒有 NLEmbedding 句向量")
        }
        let a = e.embed("holiday pictures")!, b = e.embed("vacation photos")!, c = e.embed("quarterly tax invoice")!
        XCTAssertGreaterThan(cosine(a, b), cosine(a, c))
    }

    // MARK: 分類、改名、重複、復原
    func testClassifyAndUndo() throws {
        let a = try make("a.jpg"), b = try make("b.pdf")
        let entries = FileScanner.scan(dir, recursive: false).filter { !$0.name.hasPrefix(".") }
        let plan = Classifier.plan(entries: entries, root: dir, options: .init(grouping: .year))
        XCTAssertEqual(plan.actions.count, 2)
        let j = journal()
        let res = Executor.apply(plan, selected: Set(plan.actions.map(\.id)), journal: j)
        XCTAssertEqual(res.applied, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(plan.actions.allSatisfy { FileManager.default.fileExists(atPath: $0.destination!.path) })
        XCTAssertTrue(Executor.undo(j.entries[0], journal: j).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("圖片").path), "復原後應清掉空資料夾")
    }
    func testRenameConflictGetsSuffix() throws {
        try make("a b.txt"); try make("a_b.txt")
        var rules = RenameRules(); rules.spaces = .underscore
        let plan = Renamer.plan(entries: FileScanner.scan(dir, recursive: false), rules: rules)
        XCTAssertEqual(plan.actions.count, 1)
        XCTAssertEqual(plan.actions[0].destination?.lastPathComponent, "a_b 2.txt")
    }
    func testRenameNumbering() throws {
        try make("x.png"); try make("y.png")
        var rules = RenameRules(); rules.prefix = "trip "; rules.numbering = true; rules.digits = 2
        let names = Renamer.plan(entries: FileScanner.scan(dir, recursive: false), rules: rules).actions.map { $0.destination!.lastPathComponent }
        XCTAssertEqual(names, ["trip x 01.png", "trip y 02.png"])
    }
    func testDuplicatesAndTrashUndo() throws {
        let keep = try make("one.txt", "same content"); try make("sub/two.txt", "same content"); try make("three.txt", "different")
        let groups = DuplicateFinder.find(FileScanner.scan(dir))
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].files.count, 2)
        let plan = DuplicateFinder.plan(groups)
        let j = journal()
        let res = Executor.apply(plan, selected: Set(plan.actions.map(\.id)), journal: j)
        XCTAssertEqual(res.applied, 1, res.failures.joined())
        XCTAssertEqual(FileScanner.scan(dir).filter { $0.name != ".journal.json" }.count, 2)
        XCTAssertTrue(Executor.undo(j.entries[0], journal: j).isEmpty)
        XCTAssertEqual(FileScanner.scan(dir).filter { $0.name != ".journal.json" }.count, 3)
        _ = keep
    }
    func testDiskAnalyzer() throws {
        try make("big/a.bin", String(repeating: "a", count: 5000)); try make("small/b.bin", "b"); try make("root.txt", "r")
        let r = DiskAnalyzer.analyze(entries: FileScanner.scan(dir), root: dir)
        XCTAssertEqual(r.folders.first?.name, "big")
        XCTAssertEqual(r.largestFiles.first?.name, "a.bin")
    }

    // MARK: 同名衝突

    func testConflictDetection() throws {
        let a = try make("a.txt", "new"); try make("sub/a.txt", "old")
        let plan = FileOps.move([a], into: dir.appendingPathComponent("sub"))
        XCTAssertEqual(Executor.conflicts(in: plan, selected: Set(plan.actions.map(\.id))).count, 1)
        // 沒有同名就不是衝突
        let plan2 = FileOps.move([a], into: dir.appendingPathComponent("elsewhere"))
        XCTAssertTrue(Executor.conflicts(in: plan2, selected: Set(plan2.actions.map(\.id))).isEmpty)
    }

    func testReplaceSendsOldToTrashAndUndoRestoresBoth() throws {
        let a = try make("a.txt", "new"); let old = try make("sub/a.txt", "old")
        let plan = FileOps.move([a], into: dir.appendingPathComponent("sub"))
        let j = journal()
        let res = Executor.run(plan, resolutions: [plan.actions[0].id: .replace], journal: j)
        XCTAssertTrue(res.failures.isEmpty, res.failures.joined())
        XCTAssertEqual(try String(contentsOf: old), "new", "目的地應是新內容,且保留原名")
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sub/a 2.txt").path))
        XCTAssertEqual(j.entries[0].trashed.count, 1, "舊檔應在垃圾桶並記進紀錄")

        XCTAssertTrue(Executor.undo(j.entries[0], journal: j).isEmpty)
        XCTAssertEqual(try String(contentsOf: a), "new", "新檔回到原位")
        XCTAssertEqual(try String(contentsOf: old), "old", "舊檔從垃圾桶還原")
    }

    func testKeepBothAndSkip() throws {
        let a = try make("a.txt", "new"); try make("sub/a.txt", "old"); let b = try make("b.txt", "bnew"); try make("sub/b.txt", "bold")
        let plan = FileOps.move([a, b], into: dir.appendingPathComponent("sub"))
        let res = Executor.run(plan, resolutions: [plan.actions[0].id: .keepBoth, plan.actions[1].id: .skip], journal: journal())
        XCTAssertEqual(res.applied, 1)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("sub/a.txt")), "old")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("sub/a 2.txt")), "new")
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path), "跳過的項目留在原處")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("sub/b.txt")), "bold")
    }

    func testRenameOntoExistingNameCanReplace() throws {
        let a = try make("a 2.txt", "second"); try make("a.txt", "first")
        let plan = FileOps.rename(a, to: "a.txt")
        XCTAssertEqual(Executor.conflicts(in: plan, selected: Set(plan.actions.map(\.id))).count, 1)
        let res = Executor.run(plan, resolutions: [plan.actions[0].id: .replace], journal: journal())
        XCTAssertTrue(res.failures.isEmpty, res.failures.joined())
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("a.txt")), "second")
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
    }

    func testCaseOnlyRenameIsNotAConflict() throws {
        let a = try make("photo.txt", "x")
        let plan = FileOps.rename(a, to: "Photo.txt")
        XCTAssertTrue(Executor.conflicts(in: plan, selected: Set(plan.actions.map(\.id))).isEmpty)
        let res = Executor.run(plan, journal: journal())
        XCTAssertTrue(res.failures.isEmpty, res.failures.joined())
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(names.contains("Photo.txt") && !names.contains("photo.txt"), "實際名稱: \(names)")
    }

    // MARK: 選取邏輯

    func testShiftClickSelectsContiguousRangeFromAnchor() {
        let order = (1...10).map { URL(fileURLWithPath: "/t/\($0).txt") }
        var st = SelectionLogic.State(selection: [], anchor: nil)
        st = SelectionLogic.click(order[2], command: false, shift: false, order: order, state: st)   // 點 3 → 起點
        st = SelectionLogic.click(order[6], command: false, shift: true, order: order, state: st)    // ⇧ 點 7
        XCTAssertEqual(st.selection, Set(order[2...6]))
        // 再 ⇧ 點 5:範圍改成 3…5(取代,不是疊加),起點仍是 3
        st = SelectionLogic.click(order[4], command: false, shift: true, order: order, state: st)
        XCTAssertEqual(st.selection, Set(order[2...4]))
        XCTAssertEqual(st.anchor, order[2])
        // 往起點之前也成立
        st = SelectionLogic.click(order[0], command: false, shift: true, order: order, state: st)
        XCTAssertEqual(st.selection, Set(order[0...2]))
    }

    func testCommandClickTogglesAndMovesAnchor() {
        let order = (1...6).map { URL(fileURLWithPath: "/t/\($0).txt") }
        var st = SelectionLogic.State(selection: [], anchor: nil)
        st = SelectionLogic.click(order[0], command: true, shift: false, order: order, state: st)
        st = SelectionLogic.click(order[3], command: true, shift: false, order: order, state: st)
        XCTAssertEqual(st.selection, [order[0], order[3]])
        XCTAssertEqual(st.anchor, order[3])
        st = SelectionLogic.click(order[0], command: true, shift: false, order: order, state: st)   // 再按一次取消
        XCTAssertEqual(st.selection, [order[3]])
        // ⌘ 之後 ⇧ 點擊,從最後 ⌘ 點的那個當起點
        st = SelectionLogic.click(order[5], command: false, shift: true, order: order, state: st)
        XCTAssertEqual(st.selection, Set(order[3...5]))
    }

    func testPlainClickOnSelectedMemberKeepsMultiSelection() {
        let order = (1...5).map { URL(fileURLWithPath: "/t/\($0).txt") }
        let st = SelectionLogic.State(selection: [order[1], order[2], order[3]], anchor: order[1])
        let after = SelectionLogic.click(order[2], command: false, shift: false, order: order, state: st)
        XCTAssertEqual(after.selection, st.selection, "按在已選取的多選項目上先保留,才能整組拖曳")
        let other = SelectionLogic.click(order[4], command: false, shift: false, order: order, state: st)
        XCTAssertEqual(other.selection, [order[4]])
    }

    func testShiftWithStaleAnchorFallsBackToTopmostSelected() {
        // 起點不在目前選取中(例如在別的欄位點選過):以選取中排最前面的項目為起點,不是隨機的
        let order = (1...8).map { URL(fileURLWithPath: "/t/\($0).txt") }
        let st = SelectionLogic.State(selection: [order[5], order[2]], anchor: order[7])
        let after = SelectionLogic.click(order[6], command: false, shift: true, order: order, state: st)
        XCTAssertEqual(after.selection, Set(order[2...6]))
    }

    func testShiftArrowExtendsFromAnchor() {
        let order = (1...6).map { URL(fileURLWithPath: "/t/\($0).txt") }
        var st = SelectionLogic.State(selection: [order[2]], anchor: order[2])
        st = SelectionLogic.move(to: order[3], shift: true, order: order, state: st)
        st = SelectionLogic.move(to: order[4], shift: true, order: order, state: st)
        XCTAssertEqual(st.selection, Set(order[2...4]))
        st = SelectionLogic.move(to: order[3], shift: true, order: order, state: st)   // 往回縮
        XCTAssertEqual(st.selection, Set(order[2...3]))
        st = SelectionLogic.move(to: order[5], shift: false, order: order, state: st)
        XCTAssertEqual(st.selection, [order[5]])
    }

    func testCursorIsTheMovingEndOfTheRange() {
        let order = (1...8).map { URL(fileURLWithPath: "/t/\($0).txt") }
        // 起點在前:游標在後端
        var st = SelectionLogic.State(selection: Set(order[2...5]), anchor: order[2])
        XCTAssertEqual(SelectionLogic.cursor(order: order, state: st), order[5])
        // 起點在後(往上選):游標在前端
        st = SelectionLogic.State(selection: Set(order[2...5]), anchor: order[5])
        XCTAssertEqual(SelectionLogic.cursor(order: order, state: st), order[2])
        // 單選:就是它自己
        st = SelectionLogic.State(selection: [order[4]], anchor: order[4])
        XCTAssertEqual(SelectionLogic.cursor(order: order, state: st), order[4])
        XCTAssertNil(SelectionLogic.cursor(order: order, state: .init(selection: [], anchor: nil)))
        // ⇧↓ 往下延伸後再 ⇧↑ 會縮回,而不是從前端往上擴張
        st = SelectionLogic.State(selection: [order[3]], anchor: order[3])
        for _ in 0..<2 {
            let c = SelectionLogic.cursor(order: order, state: st)!
            st = SelectionLogic.move(to: order[order.firstIndex(of: c)! + 1], shift: true, order: order, state: st)
        }
        XCTAssertEqual(st.selection, Set(order[3...5]))
        let c = SelectionLogic.cursor(order: order, state: st)!
        st = SelectionLogic.move(to: order[order.firstIndex(of: c)! - 1], shift: true, order: order, state: st)
        XCTAssertEqual(st.selection, Set(order[3...4]), "往回縮一格")
    }

    // MARK: 資料夾分析

    func testFolderAnalysisCountsAndCategories() throws {
        try make("a.jpg", String(repeating: "x", count: 3000)); try make("b.png", String(repeating: "x", count: 1000))
        try make("doc/notes.txt", "hello"); try make("doc/empty.txt", ""); try make("clip.mp4", String(repeating: "x", count: 500))
        let a = try XCTUnwrap(FolderAnalyzer.analyze(dir))
        XCTAssertEqual(a.fileCount, 5)
        XCTAssertEqual(a.folderCount, 1)
        XCTAssertEqual(a.emptyFileCount, 1)
        XCTAssertEqual(a.totalBytes, 3000 + 1000 + 5 + 500)
        XCTAssertEqual(a.categories.first?.id, FileCategory.images.rawValue, "圖片占最多位元組")
        XCTAssertEqual(a.categories.first?.count, 2)
        XCTAssertEqual(a.largest.first?.relativePath, "a.jpg")
        XCTAssertEqual(a.children.first?.name, "a.jpg")
        XCTAssertEqual(a.maxDepth, 2)
        XCTAssertFalse(a.summaryText().isEmpty)
    }

    func testFolderAnalysisDetectsProjectsAndSkipsDependencyFolders() throws {
        try make("Package.swift", "// swift"); try make(".git/HEAD", "ref"); try make("web/package.json", "{}")
        try make("web/node_modules/dep/index.js", "x"); try make("web/node_modules/dep/more.js", "y")
        try make("proj/Game.xcodeproj/project.pbxproj", "z")
        let a = try XCTUnwrap(FolderAnalyzer.analyze(dir))
        XCTAssertTrue(["swiftpm", "git", "node", "xcode"].allSatisfy(a.projects.contains), "偵測到:\(a.projects)")
        XCTAssertTrue(a.skippedDirs.contains("node_modules"))
        XCTAssertTrue(a.skippedDirs.contains(".git"))
        XCTAssertFalse(a.largest.contains { $0.relativePath.contains("node_modules") }, "不應進入 node_modules")
    }

    func testFolderAnalysisEmptyTruncatedAndCancelled() throws {
        let empty = try XCTUnwrap(FolderAnalyzer.analyze(dir))
        XCTAssertTrue(empty.isEmpty)
        for i in 0..<30 { try make("f\(i).txt", "x") }
        let cut = try XCTUnwrap(FolderAnalyzer.analyze(dir, maxEntries: 10))
        XCTAssertTrue(cut.truncated)
        XCTAssertNil(FolderAnalyzer.analyze(dir, isCancelled: { true }), "被取消時回傳 nil")
    }

    func testAnalysisStoreRoundTrip() throws {
        try make("x.txt", "hi")
        let store = AnalysisStore(directory: dir.appendingPathComponent(".analyses"))
        XCTAssertFalse(store.exists(dir.path))
        let a = try XCTUnwrap(FolderAnalyzer.analyze(dir))
        store.save(a)
        XCTAssertTrue(store.exists(dir.path))
        let loaded = try XCTUnwrap(store.load(dir.path))
        XCTAssertEqual(loaded.fileCount, a.fileCount)
        XCTAssertEqual(loaded.path, a.path)
        store.delete(dir.path)
        XCTAssertFalse(store.exists(dir.path))
    }

    // MARK: 自訂側邊欄

    func testSidebarDefaultsAndNormalize() {
        let d = SidebarLayout.defaults
        XCTAssertEqual(d.visibleEntries.count, SidebarLayout.builtinIDs.count)
        // 舊設定缺少某個預設位置、重複、有未知代號:都會被修正
        let messy = SidebarLayout(entries: [SidebarEntry(builtin: "home"), SidebarEntry(builtin: "home"), SidebarEntry(builtin: "bogus"),
                                            SidebarEntry(path: "/tmp/x")])
        XCTAssertEqual(messy.entries.filter { $0.builtin == "home" }.count, 1)
        XCTAssertFalse(messy.entries.contains { $0.builtin == "bogus" })
        XCTAssertEqual(Set(messy.entries.compactMap(\.builtin)), Set(SidebarLayout.builtinIDs))
        XCTAssertEqual(messy.visibleEntries.count, 2, "缺少的預設位置補成隱藏,不會突然冒出來")
    }

    func testSidebarAddFolderDedupes() {
        var l = SidebarLayout.defaults
        let builtinPaths = ["desktop": "/Users/me/Desktop", "downloads": "/Users/me/Downloads"]
        guard case .added(let id) = l.addFolder("/Users/me/Projects/", builtinPaths: builtinPaths) else { return XCTFail() }
        XCTAssertEqual(l.entries.last?.path, "/Users/me/Projects", "結尾斜線會被整理掉")
        XCTAssertEqual(l.addFolder("/Users/me/Projects", builtinPaths: builtinPaths), .alreadyThere(id))
        // 加入的是預設位置:只是把它顯示出來
        let desk = l.entries.first { $0.builtin == "desktop" }!.id
        XCTAssertEqual(l.addFolder("/Users/me/Desktop", builtinPaths: builtinPaths), .alreadyThere(desk))
        l.remove(desk)
        XCTAssertTrue(l.entries.first { $0.id == desk }!.hidden)
        XCTAssertEqual(l.addFolder("/Users/me/Desktop", builtinPaths: builtinPaths), .revealedBuiltin(desk))
        XCTAssertFalse(l.entries.first { $0.id == desk }!.hidden)
    }

    func testSidebarRemoveRenameAndRestore() {
        var l = SidebarLayout.defaults
        guard case .added(let id) = l.addFolder("/tmp/work") else { return XCTFail() }
        l.customize(id, title: "  工作  ", symbol: "briefcase")
        XCTAssertEqual(l.entries.last?.title, "工作")
        XCTAssertEqual(l.entries.last?.symbol, "briefcase")
        l.customize(id, title: "", symbol: nil)
        XCTAssertNil(l.entries.last?.title)
        XCTAssertNil(l.entries.last?.symbol)
        l.remove(id)
        XCTAssertFalse(l.entries.contains { $0.id == id }, "自訂資料夾直接刪除")
        l.setHidden(l.entries[0].id, true)
        l.addFolder("/tmp/a")
        l.restoreDefaults()
        // 還原預設後內容與預設相同(每個項目的 ID 會重新產生,所以只比內容)
        XCTAssertEqual(l.entries.map(\.builtin), SidebarLayout.builtinIDs.map { Optional($0) })
        XCTAssertTrue(l.entries.allSatisfy { !$0.hidden && $0.title == nil && $0.symbol == nil && $0.path == nil })
    }

    func testSidebarMoveVisibleKeepsHiddenInPlace() {
        var l = SidebarLayout(entries: [
            SidebarEntry(builtin: "home"), SidebarEntry(builtin: "desktop", hidden: true),
            SidebarEntry(builtin: "documents"), SidebarEntry(path: "/tmp/p"),
        ])
        let before = l.entries.map(\.id)
        // 側邊欄上看到的是 [home, documents, /tmp/p];把最後一個拖到最前面
        l.moveVisible(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(l.visibleEntries.map { $0.builtin ?? $0.path }, ["/tmp/p", "home", "documents"])
        XCTAssertTrue(l.entries[1].hidden, "被隱藏的項目仍在原本的位置")
        XCTAssertEqual(Set(l.entries.map(\.id)), Set(before), "沒有項目遺失或重複")
        // 往後拖:把第一個拖到最後(onMove 的目的地是搬移前的插入點)
        l.moveVisible(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(l.visibleEntries.map { $0.builtin ?? $0.path }, ["home", "documents", "/tmp/p"])
    }

    func testSidebarCodableRoundTrip() throws {
        var l = SidebarLayout.defaults
        l.addFolder("/tmp/z", title: "Z"); l.showTools = false
        let data = try JSONEncoder().encode(l)
        let back = try JSONDecoder().decode(SidebarLayout.self, from: data)
        XCTAssertEqual(back, l)
        XCTAssertFalse(back.showTools)
    }

    func testSidebarMoveShownSubset() {
        var l = SidebarLayout(entries: [
            SidebarEntry(builtin: "home"), SidebarEntry(builtin: "desktop"), SidebarEntry(builtin: "documents"),
            SidebarEntry(builtin: "downloads"), SidebarEntry(path: "/tmp/p"),
        ])
        l.setHidden(l.entries.first { $0.builtin == "pictures" }!.id, true)
        // 畫面上其實只顯示 home / documents / downloads(desktop 因資料夾不存在而沒顯示,但沒有被隱藏)
        let shown = [l.entries[0].id, l.entries[2].id, l.entries[3].id]
        l.moveShown(shown, from: IndexSet(integer: 2), to: 0)   // 把 downloads 拖到最前面
        XCTAssertEqual(l.entries.prefix(5).map { $0.builtin ?? $0.path }, ["downloads", "desktop", "home", "documents", "/tmp/p"])
    }
}
