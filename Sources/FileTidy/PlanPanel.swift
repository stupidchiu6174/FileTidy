import SwiftUI
import FileTidyCore

/// 所有功能共用的「預覽並確認」面板。
struct PlanPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let plan = model.plan, !plan.actions.isEmpty {
            VStack(spacing: 0) {
                HStack {
                    Text("預覽:\(plan.title)").font(.headline)
                    Text("(已勾選 \(model.selected.count) / \(plan.actions.count))").foregroundStyle(.secondary)
                    Spacer()
                    Button("全選") { model.selected = Set(plan.actions.map(\.id)) }
                    Button("全不選") { model.selected = [] }
                    Button("取消預覽") { model.clearPlan() }
                    Button("套用所選…") { model.confirmApply = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.selected.isEmpty)
                }
                .padding(10)
                List(plan.actions) { action in
                    HStack(alignment: .top) {
                        Toggle("", isOn: Binding(
                            get: { model.selected.contains(action.id) },
                            set: { on in if on { model.selected.insert(action.id) } else { model.selected.remove(action.id) } }
                        )).labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            switch action.kind {
                            case .move:
                                Text(model.relative(action.source)).lineLimit(1).truncationMode(.middle)
                                Label(model.relative(action.destination ?? action.source), systemImage: "arrow.turn.down.right")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            case .copy:
                                Text(model.relative(action.source)).lineLimit(1).truncationMode(.middle)
                                Label(model.relative(action.destination ?? action.source), systemImage: "plus.square.on.square")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            case .mkdir:
                                Label(model.relative(action.destination ?? action.source), systemImage: "folder.badge.plus")
                                    .lineLimit(1).truncationMode(.middle)
                            case .trash:
                                Label(model.relative(action.source), systemImage: "trash")
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            if !action.note.isEmpty {
                                Text(action.note).font(.caption2).foregroundStyle(.orange)
                            }
                        }
                    }
                }
                .frame(minHeight: 160)
            }
            .confirmationDialog("確定要套用 \(model.selected.count) 項操作?", isPresented: Binding(
                get: { model.confirmApply }, set: { model.confirmApply = $0 }), titleVisibility: .visible) {
                Button("套用") { model.applyPlan() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("檔案只會被移動或放進垃圾桶,不會直接刪除;之後可在「復原紀錄」還原。")
            }
        }
    }
}
