import SwiftUI
import Charts
import AppKit
import FileTidyCore

/// 要求分析某個資料夾;rerun = true 表示忽略已存的結果,重新掃描
struct AnalysisRequest: Identifiable {
    let url: URL
    var rerun = false
    var id: String { url.path + (rerun ? "#rerun" : "") }
}

@MainActor @Observable
final class FolderAnalysisModel {
    enum Phase { case scanning, done, failed }
    enum AIState { case idle, generating, done, unavailable(String) }

    let url: URL
    var phase: Phase = .scanning
    var scanned = 0
    var analysis: FolderAnalysis?
    var fromCache = false
    var ai: AIState = .idle
    private var scanTask: Task<Void, Never>?
    private var aiTask: Task<Void, Never>?

    init(url: URL) { self.url = url }

    /// 有已存的結果就直接顯示(右鍵選單「查看分析結果」),否則重新掃描
    func open(rerun: Bool) {
        if !rerun, let cached = AnalysisStore.shared.load(url.path) {
            analysis = cached
            fromCache = true
            phase = .done
            if let text = cached.aiSummary, !text.isEmpty { ai = .done }
            return
        }
        scan()
    }

    func scan() {
        cancel()
        phase = .scanning
        scanned = 0
        analysis = nil
        fromCache = false
        ai = .idle
        let target = url
        scanTask = Task {
            let result = await Task.detached(priority: .utility) { () -> FolderAnalysis? in
                // 進度只在背景更新計數器,再由主執行緒顯示,不讓每個項目都觸發畫面更新
                FolderAnalyzer.analyze(target, progress: { n in Task { @MainActor in self.scanned = n } },
                                       isCancelled: { Task.isCancelled })
            }.value
            guard !Task.isCancelled else { return }
            if let result {
                AnalysisStore.shared.save(result)
                analysis = result
                phase = .done
                generateAI()
            } else {
                phase = .failed
            }
        }
    }

    func generateAI() {
        guard let current = analysis else { return }
        aiTask?.cancel()
        ai = .generating
        aiTask = Task {
            let result = await AISummarizer.summarize(current)
            guard !Task.isCancelled else { return }
            switch result {
            case .text(let text):
                var updated = current
                updated.aiSummary = text
                analysis = updated
                AnalysisStore.shared.save(updated)
                ai = .done
            case .unavailable(let why):
                ai = .unavailable(why)
            }
        }
    }

    func cancel() { scanTask?.cancel(); aiTask?.cancel() }

    /// 可以貼到別處的完整文字
    var plainText: String {
        guard let a = analysis else { return "" }
        var out = a.summaryText()
        if let ai = a.aiSummary, !ai.isEmpty { out += "\n\n" + ai }
        return out
    }
}

struct FolderAnalysisSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: AnalysisRequest
    @State private var vm: FolderAnalysisModel

    init(request: AnalysisRequest) {
        self.request = request
        _vm = State(initialValue: FolderAnalysisModel(url: request.url))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        // 高度不固定:主視窗最小只有 432 高,固定 700 會讓底部按鈕跑出視窗外;內容由捲動區處理
        .frame(minWidth: 520, idealWidth: 680, maxWidth: 760, minHeight: 340, idealHeight: 540, maxHeight: 800)
        .task { vm.open(rerun: request.rerun) }
        .onDisappear { vm.cancel() }
    }

    // MARK: 標題

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: vm.url.path)).resizable().frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.url.lastPathComponent).font(.title3.bold()).lineLimit(1)
                Text(vm.url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            if let a = vm.analysis {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(vm.fromCache ? "已存的分析結果" : "剛完成的分析").font(.caption).foregroundStyle(.secondary)
                    Text(a.analyzedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(16)
    }

    // MARK: 內容

    @ViewBuilder private var content: some View {
        switch vm.phase {
        case .scanning:
            VStack(spacing: 14) {
                ProgressView()
                Text("正在分析這個資料夾裡有什麼…").font(.headline)
                Text("已掃描 \(vm.scanned.formatted()) 個項目").foregroundStyle(.secondary).monospacedDigit()
                Button("取消") { vm.cancel(); dismiss() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView("分析失敗", systemImage: "exclamationmark.triangle",
                                   description: Text("無法讀取這個資料夾,或分析被取消了。"))
        case .done:
            if let a = vm.analysis { results(a) }
        }
    }

    private func results(_ a: FolderAnalysis) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                summaryCard(a)
                if !a.isEmpty { details(a) }
            }
            .padding(16)
        }
    }

    private func summaryCard(_ a: FolderAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("這個資料夾裡有什麼", systemImage: "text.magnifyingglass").font(.headline)
            Text(a.summaryText()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)

            switch vm.ai {
            case .idle: EmptyView()
            case .generating:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("裝置端 AI 正在整理說明…").foregroundStyle(.secondary) }
            case .done:
                if let text = a.aiSummary {
                    Divider()
                    Label("AI 摘要(在這台 Mac 上產生,不會上傳)", systemImage: "sparkles").font(.subheadline.bold()).foregroundStyle(.purple)
                    Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text("AI 可能寫錯細節(例如檔名),請以上方與下方的統計為準。").font(.caption2).foregroundStyle(.secondary)
                }
            case .unavailable(let why):
                Divider()
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(.secondary)
                    Text(why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(Color.accentColor.opacity(0.12)), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder private func details(_ a: FolderAnalysis) -> some View {
        overview(a)
        if !a.categories.isEmpty { section("檔案類型", systemImage: "chart.bar.xaxis") { categoryChart(a) } }
        if !a.projects.isEmpty || !a.skippedDirs.isEmpty { section("偵測到的專案與依賴", systemImage: "hammer") { projectChips(a) } }
        if !a.children.isEmpty { section("最占空間的項目", systemImage: "folder") { children(a) } }
        if !a.extensions.isEmpty { section("常見的副檔名", systemImage: "number") { extensions(a) } }
        if !a.largest.isEmpty { section("最大的檔案", systemImage: "arrow.up.right.square") { fileList(a.largest, showSize: true) } }
        if !a.recent.isEmpty { section("最近修改的檔案", systemImage: "clock") { fileList(a.recent, showSize: false) } }
    }

    // MARK: 區塊

    private func section<C: View>(_ title: LocalizedStringKey, systemImage: String, @ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage).font(.headline)
            body()
        }
    }

    private func overview(_ a: FolderAnalysis) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
            GridRow {
                stat("檔案", a.fileCount.formatted())
                stat("資料夾", a.folderCount.formatted())
                stat("總大小", formatBytes(a.totalBytes))
                stat("最深層數", a.maxDepth.formatted())
            }
            GridRow {
                stat("隱藏項目", a.hiddenCount.formatted())
                stat("空檔案", a.emptyFileCount.formatted())
                stat("最舊", a.oldest?.formatted(date: .abbreviated, time: .omitted) ?? "—")
                stat("最新", a.newest?.formatted(date: .abbreviated, time: .omitted) ?? "—")
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func stat(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit().lineLimit(1)
        }
    }

    private func categoryChart(_ a: FolderAnalysis) -> some View {
        Chart(a.categories, id: \.id) { c in
            BarMark(x: .value("大小", c.bytes), y: .value("類型", FileCategory(rawValue: c.id)?.title ?? c.id))
                .foregroundStyle(by: .value("類型", FileCategory(rawValue: c.id)?.title ?? c.id))
                .cornerRadius(4)
                .annotation(position: .trailing) {
                    Text("\(c.count.formatted()) · \(formatBytes(c.bytes))").font(.caption2).foregroundStyle(.secondary)
                }
        }
        .chartLegend(.hidden)
        .chartXAxis(.hidden)
        .frame(height: CGFloat(max(a.categories.count, 1)) * 30 + 8)
    }

    private func projectChips(_ a: FolderAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !a.projects.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(a.projects, id: \.self) { id in
                        Text(FolderAnalysis.projectName(id)).font(.callout)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                    }
                }
            }
            if !a.skippedDirs.isEmpty {
                Text("為了速度沒有逐一統計:\(a.skippedDirs.joined(separator: String(localized: "、")))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func children(_ a: FolderAnalysis) -> some View {
        let maxBytes = max(a.children.map(\.bytes).max() ?? 1, 1)
        return VStack(spacing: 4) {
            ForEach(a.children, id: \.name) { c in
                Button { openChild(c, in: a) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: c.isDirectory ? "folder.fill" : "doc").foregroundStyle(c.isDirectory ? Color.accentColor : .secondary).frame(width: 18)
                        Text(c.name).lineLimit(1).truncationMode(.middle).frame(width: 190, alignment: .leading)
                        GeometryReader { g in
                            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.accentColor.opacity(0.55))
                                .frame(width: max(2, g.size.width * CGFloat(c.bytes) / CGFloat(maxBytes)))
                        }
                        .frame(height: 10)
                        Text(formatBytes(c.bytes)).font(.caption).monospacedDigit().frame(width: 70, alignment: .trailing)
                        Text("\(c.fileCount.formatted())").font(.caption2).foregroundStyle(.secondary).monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func extensions(_ a: FolderAnalysis) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
            ForEach(a.extensions, id: \.ext) { e in
                GridRow {
                    Text(e.ext.isEmpty ? String(localized: "(沒有副檔名)") : ".\(e.ext)").font(.callout.monospaced())
                    Text("\(e.count.formatted())").monospacedDigit().foregroundStyle(.secondary)
                    Text(formatBytes(e.bytes)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }

    private func fileList(_ files: [FolderAnalysis.AnalyzedFile], showSize: Bool) -> some View {
        VStack(spacing: 2) {
            ForEach(files, id: \.relativePath) { f in
                let full = vm.url.appendingPathComponent(f.relativePath)
                Button { reveal(full) } label: {
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: full.path)).resizable().frame(width: 20, height: 20)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(full.lastPathComponent).lineLimit(1)
                            Text(f.relativePath).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                        Spacer()
                        Text(showSize ? formatBytes(f.size) : f.modified.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 底部按鈕與動作

    private var footer: some View {
        HStack {
            Button("重新分析") { vm.scan() }.disabled(vm.phase == .scanning)
            Button("拷貝摘要") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(vm.plainText, forType: .string)
            }
            .disabled(vm.analysis == nil)
            if case .unavailable = vm.ai { Button("再試一次 AI 摘要") { vm.generateAI() } }
            Spacer()
            Button("關閉") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.glassProminent)
        }
        .padding(12)
    }

    private func openChild(_ c: FolderAnalysis.Child, in a: FolderAnalysis) {
        let target = vm.url.appendingPathComponent(c.name)
        dismiss()
        if c.isDirectory { model.open(target) } else { model.open(vm.url, select: target) }
    }

    private func reveal(_ url: URL) {
        dismiss()
        model.open(url.deletingLastPathComponent(), select: url)
    }
}

/// 讓標籤自動換行的簡單版面
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(in: proposal.width ?? 600, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(in: bounds.width, subviews: subviews)
        for (i, origin) in result.origins.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func layout(in width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        var origins: [CGPoint] = []
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
            maxX = max(maxX, x - spacing)
        }
        return (origins, CGSize(width: maxX, height: y + rowHeight))
    }
}
