import AppKit
import FileTidyCore

/// Finder「檔案」選單裡的功能。所有會改動檔案的操作都寫入復原紀錄(⌘Z)。
extension AppModel {
    /// 目前選取的項目(瀏覽時是表格選取,搜尋結果時是搜尋選取),依路徑排序以便行為穩定
    var effectiveSelection: [URL] {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let urls = searching ? searchSelection.map { URL(fileURLWithPath: $0) } : Array(tab.selection)
        return urls.sorted { $0.path < $1.path }
    }

    // MARK: 開啟

    func openSelection() { effectiveSelection.forEach(activate) }

    func openWithApps(for url: URL) -> [(name: String, url: URL)] {
        NSWorkspace.shared.urlsForApplications(toOpen: url).map {
            (FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: ""), $0)
        }
    }

    func open(_ file: URL, with app: URL) {
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func showEnclosingFolder() {
        guard let url = effectiveSelection.first else { return }
        open(url.deletingLastPathComponent(), select: url)
    }

    // MARK: 建立

    /// 「以選取項目建立新資料夾」:建立資料夾,並把選取的項目放進去
    func newFolderWithSelection() {
        let urls = effectiveSelection
        guard let first = urls.first else { return }
        let folder = Executor.uniqueURL(first.deletingLastPathComponent()
            .appendingPathComponent(String(localized: "新增項目資料夾"), isDirectory: true))
        let actions = urls.map {
            PlannedAction(kind: .move, source: $0, destination: folder.appendingPathComponent($0.lastPathComponent))
        }
        perform(OperationPlan(title: String(localized: "以選取項目建立新資料夾"), actions: actions))
        if FileManager.default.fileExists(atPath: folder.path) {
            tab.selection = [folder]
            renameTarget = folder
        }
    }

    /// 壓縮成 .zip(單一項目用原名,多個項目叫「封存」)
    func compressSelection() {
        let urls = effectiveSelection
        guard let first = urls.first else { return }
        let base = urls.count == 1 ? first.lastPathComponent : String(localized: "封存")
        let dest = Executor.uniqueURL(first.deletingLastPathComponent().appendingPathComponent(base + ".zip"))
        busy = true
        status = String(localized: "壓縮中…")
        Task {
            let ok = await Task.detached { () -> Bool in
                func run(_ tool: String, _ args: [String]) -> Bool {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: tool)
                    p.arguments = args
                    p.standardError = Pipe()
                    do { try p.run() } catch { return false }
                    p.waitUntilExit()
                    return p.terminationStatus == 0
                }
                if urls.count == 1 {
                    // --keepParent 會把「父資料夾名稱」包進壓縮檔:資料夾要保留自己的名字,單一檔案則不應多出一層
                    let isDir = (try? urls[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    let flags = isDir ? ["-c", "-k", "--sequesterRsrc", "--keepParent"] : ["-c", "-k", "--sequesterRsrc"]
                    return run("/usr/bin/ditto", flags + [urls[0].path, dest.path])
                }
                // ditto 一次只能壓縮一個來源:多個項目先用 APFS clone 放進暫存資料夾(幾乎不佔空間),再整個壓縮
                let staging = FileManager.default.temporaryDirectory.appendingPathComponent("filetidy-zip-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: staging) }
                guard (try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)) != nil else { return false }
                for u in urls where !run("/bin/cp", ["-cR", u.path, staging.path + "/"]) { return false }
                return run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", staging.path, dest.path])
            }.value
            busy = false
            if ok {
                journal.recordCreated(title: String(localized: "壓縮"), paths: [dest.path])
                history = journal.entries
                status = String(localized: "已建立「\(dest.lastPathComponent)」(⌘Z 可復原)")
                tab.reload()
                tab.selection = [dest]
            } else {
                status = String(localized: "壓縮失敗")
            }
        }
    }

    /// 製作替身(Finder 的別名檔)
    func makeAlias() {
        var created: [String] = []
        for url in effectiveSelection {
            let name = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let aliasName = name + String(localized: " 替身") + (ext.isEmpty ? "" : "." + ext)
            let dest = Executor.uniqueURL(url.deletingLastPathComponent().appendingPathComponent(aliasName))
            do {
                let data = try url.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
                try URL.writeBookmarkData(data, to: dest)
                created.append(dest.path)
            } catch {
                status = String(localized: "無法建立替身:\(error.localizedDescription)")
            }
        }
        guard !created.isEmpty else { return }
        journal.recordCreated(title: String(localized: "製作替身"), paths: created)
        history = journal.entries
        status = String(localized: "已建立 \(created.count) 個替身(⌘Z 可復原)")
        tab.reload()
    }

    // MARK: 其他

    func showInfo() { infoTarget = effectiveSelection.first }

    /// 選了一個資料夾就分析它;沒選東西就分析目前所在的資料夾
    func analyzeSelectionOrCurrent() {
        let sel = effectiveSelection
        if sel.count == 1, isBrowsableFolder(sel[0]) { analysisTarget = AnalysisRequest(url: sel[0]) }
        else if sel.isEmpty { analysisTarget = AnalysisRequest(url: currentFolder) }
    }

    func quickLookSelection() { quickLookURL = effectiveSelection.first }

    func renameSelection() { renameTarget = effectiveSelection.first }

    func shareSelection() {
        let urls = effectiveSelection
        guard !urls.isEmpty, let window = FileTidyIntegration.window ?? NSApp.keyWindow,
              let table = window.contentView.flatMap({ Self.findFileTable(in: $0) }) else { return }
        NSSharingServicePicker(items: urls).show(relativeTo: NSRect(x: 8, y: 8, width: 1, height: 1), of: table, preferredEdge: .minY)
    }

    /// 取出磁碟(選取的是 /Volumes 底下的磁碟本身時)
    var canEject: Bool {
        guard let url = effectiveSelection.first, effectiveSelection.count == 1 else { return false }
        return url.deletingLastPathComponent().path == "/Volumes"
    }

    func ejectSelection() {
        guard canEject, let url = effectiveSelection.first else { return }
        do { try NSWorkspace.shared.unmountAndEjectDevice(at: url); status = String(localized: "已取出「\(url.lastPathComponent)」") }
        catch { status = String(localized: "無法取出:\(error.localizedDescription)") }
    }

    // MARK: 標籤(Finder 標籤;名稱使用系統內建的顏色標籤)

    static let colorTags: [(name: String, color: NSColor)] = [
        ("Red", .systemRed), ("Orange", .systemOrange), ("Yellow", .systemYellow),
        ("Green", .systemGreen), ("Blue", .systemBlue), ("Purple", .systemPurple), ("Gray", .systemGray),
    ]

    func selectionHasTag(_ name: String) -> Bool {
        let urls = effectiveSelection
        guard !urls.isEmpty else { return false }
        return urls.allSatisfy { ((try? $0.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []).contains(name) }
    }

    /// 選取項目全都有這個標籤就移除,否則全部加上
    func toggleTag(_ name: String) {
        let remove = selectionHasTag(name)
        for url in effectiveSelection {
            var tags = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
            if remove { tags.removeAll { $0 == name } } else if !tags.contains(name) { tags.append(name) }
            // URLResourceValues.tagNames 的 setter 要 macOS 26 才有,用 NSURL 的介面相容較舊的系統
            try? (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        }
        tab.reload()
        refreshIntegration()  // 讓選單的勾選狀態重新計算
    }
}
