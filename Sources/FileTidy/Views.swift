import SwiftUI
import Charts
import FileTidyCore

// MARK: - 範圍選擇(工具共用)

enum ToolScope: String, CaseIterable, Identifiable {
    case folder, everywhere
    var id: String { rawValue }
    var title: LocalizedStringKey { self == .folder ? "目前資料夾" : "整台 Mac" }
}

// MARK: - 自動分類

struct OrganizeView: View {
    @Environment(AppModel.self) private var model
    @State private var grouping: DateGrouping = .yearMonth
    @State private var useCreation = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("日期層級", selection: $grouping) {
                    ForEach(DateGrouping.allCases, id: \.self) { Text($0.title).tag($0) }
                }.frame(width: 220)
                Toggle("使用建立日期", isOn: $useCreation)
                Spacer()
                Button("產生預覽") { Task { await preview() } }.buttonStyle(.borderedProminent)
            }.padding(12)
            Text("只處理「\(model.currentFolder.lastPathComponent)」第一層的檔案,依類型(圖片/文件/…)與日期放進子資料夾。要換資料夾,先到「瀏覽」切換位置。")
                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
            Spacer(minLength: 0)
            PlanPanel()
        }
    }

    private func preview() async {
        let entries = await model.scanCurrent(recursive: false)
        model.setPlan(Classifier.plan(entries: entries, root: model.currentFolder,
                                      options: .init(grouping: grouping, useCreationDate: useCreation)))
    }
}

// MARK: - 重複檔案

struct DuplicatesView: View {
    @Environment(AppModel.self) private var model
    @State private var scope: ToolScope = .folder
    @State private var groups: [DuplicateGroup] = []
    @State private var progress: (Int, Int)?
    @State private var scanned = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("範圍", selection: $scope) { ForEach(ToolScope.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 220)
                if let p = progress { ProgressView(value: Double(p.0), total: Double(max(p.1, 1))).frame(width: 140) }
                Text(scanned ? String(localized: "找到 \(groups.count) 組重複,可釋出 \(formatBytes(groups.reduce(0) { $0 + $1.wastedBytes }))") : "")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("掃描") { Task { await scan() } }
                Button("產生清理預覽(每組保留最舊)") { model.setPlan(DuplicateFinder.plan(groups)) }
                    .buttonStyle(.borderedProminent).disabled(groups.isEmpty)
            }.padding(12)

            if groups.isEmpty {
                ContentUnavailableView(scanned ? String(localized: "沒有重複檔案") : String(localized: "按「掃描」開始"), systemImage: "doc.on.doc",
                                       description: Text(scope == .everywhere ? String(localized: "整台 Mac 模式只比對 1 KB 以上的檔案,並使用已建立的索引。") : ""))
            } else {
                List(groups) { g in
                    DisclosureGroup {
                        ForEach(g.files) { f in
                            HStack {
                                Text(model.relative(f.url)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button { model.reveal(f.url) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                            }
                        }
                    } label: {
                        Text("\(g.files[0].name)  ×\(g.files.count)  ·  \(formatBytes(g.size)),浪費 \(formatBytes(g.wastedBytes))")
                    }
                }
            }
            PlanPanel()
        }
        .onChange(of: model.currentFolder) { groups = []; scanned = false }
    }

    private func scan() async {
        model.clearPlan()
        let entries: [FileEntry]
        if scope == .everywhere {
            entries = await model.catalog.snapshot(scope: nil, minSize: 1024)
        } else {
            entries = await model.scanCurrent(recursive: true)
        }
        progress = (0, 1)
        let found = await Task.detached(priority: .userInitiated) {
            DuplicateFinder.find(entries) { done, total in Task { @MainActor in progress = (done, total) } }
        }.value
        groups = found
        scanned = true
        progress = nil
        model.status = String(localized: "比對了 \(entries.count.formatted()) 個檔案")
    }
}

// MARK: - 批次改名

struct RenameView: View {
    @Environment(AppModel.self) private var model
    @State private var rules = RenameRules()
    @State private var entries: [FileEntry] = []
    @State private var recursive = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                HStack {
                    TextField("尋找", text: $rules.find)
                    TextField("取代為", text: $rules.replace)
                }
                HStack {
                    TextField("前綴", text: $rules.prefix)
                    TextField("後綴", text: $rules.suffix)
                }
                HStack {
                    Picker("空格", selection: $rules.spaces) { ForEach(RenameRules.SpaceMode.allCases, id: \.self) { Text($0.title).tag($0) } }
                    Picker("大小寫", selection: $rules.caseMode) { ForEach(RenameRules.CaseMode.allCases, id: \.self) { Text($0.title).tag($0) } }
                }
                HStack {
                    Toggle("加上日期", isOn: $rules.insertDate)
                    Toggle("加上序號", isOn: $rules.numbering)
                    Stepper("起始 \(rules.startNumber)", value: $rules.startNumber, in: 0...9999).disabled(!rules.numbering)
                    Stepper("位數 \(rules.digits)", value: $rules.digits, in: 1...6).disabled(!rules.numbering)
                    Spacer()
                    Toggle("包含子資料夾", isOn: $recursive)
                    Button("載入「\(model.currentFolder.lastPathComponent)」的檔案") { Task { await load() } }
                }
            }
            .padding(12)
            Text(entries.isEmpty ? String(localized: "先載入檔案,調整規則時會即時更新預覽。") : String(localized: "已載入 \(entries.count) 個檔案"))
                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
            Spacer(minLength: 0)
            PlanPanel()
        }
        .onChange(of: rules) { refresh() }
        .onChange(of: model.currentFolder) { entries = [] }
    }

    private func load() async {
        entries = await model.scanCurrent(recursive: recursive)
        refresh()
    }

    private func refresh() {
        guard !entries.isEmpty, !rules.isIdentity else { return }
        model.setPlan(Renamer.plan(entries: entries, rules: rules))
    }
}

// MARK: - 空間分析

struct DiskView: View {
    @Environment(AppModel.self) private var model
    @State private var scope: ToolScope = .folder
    @State private var report: DiskReport?
    @State private var reportRoot: URL?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("範圍", selection: $scope) { ForEach(ToolScope.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 220)
                if let r = report { Text("總計 \(formatBytes(r.totalBytes))").font(.headline) }
                Spacer()
                Button("分析") { Task { await analyze() } }.buttonStyle(.borderedProminent)
            }.padding(12)

            if let report, let root = reportRoot {
                HSplitView {
                    Chart(report.folders.prefix(12)) { f in
                        BarMark(x: .value(String(localized: "大小"), f.bytes), y: .value(String(localized: "資料夾"), f.url == root ? String(localized: "(根目錄檔案)") : f.name))
                            .annotation(position: .trailing) { Text(formatBytes(f.bytes)).font(.caption2) }
                    }
                    .chartXAxis(.hidden)
                    .padding().frame(minWidth: 320)

                    List(report.largestFiles) { f in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(f.name).lineLimit(1)
                                Text(model.relative(f.url)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(formatBytes(f.size)).monospacedDigit()
                            Button { model.reveal(f.url) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                            Button { model.setPlan(FileOps.trash([f.url])) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                    }
                    .frame(minWidth: 380)
                }
            } else {
                ContentUnavailableView("按「分析」開始", systemImage: "chart.bar.xaxis")
            }
            PlanPanel()
        }
        .onChange(of: model.currentFolder) { report = nil }
    }

    private func analyze() async {
        let root = scope == .everywhere ? FileManager.default.homeDirectoryForCurrentUser : model.currentFolder
        let prefix = root.path
        let entries = await model.catalog.snapshot(scope: prefix)
        report = await Task.detached { DiskAnalyzer.analyze(entries: entries, root: root) }.value
        reportRoot = root
        let scopeName = scope == .everywhere ? String(localized: "個人資料夾") : root.lastPathComponent
        model.status = String(localized: "分析了 \(entries.count.formatted()) 個檔案(來自索引,\(scopeName))")
    }
}

// MARK: - 操作紀錄

struct HistoryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.history.isEmpty {
            ContentUnavailableView("還沒有操作紀錄", systemImage: "clock.arrow.circlepath")
        } else {
            List(model.history) { e in
                HStack {
                    VStack(alignment: .leading) {
                        Text(e.title).font(.headline)
                        Text("\(e.date.formatted(date: .abbreviated, time: .shortened)) · \(e.count) 項")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if e.undone { Text("已復原").foregroundStyle(.secondary) } else { Button("復原") { model.undo(e) } }
                }
            }
        }
    }
}
